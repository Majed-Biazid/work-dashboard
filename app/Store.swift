// The app's single source of truth: config, local state, and the latest output of
// every collector. Collectors run on their own timers; each result is cached on
// disk (so a launch is instant) and pushed to every open page at once.

import Foundation
import CoreServices

/// Calls `changed` on the main queue when anything inside `folder` changes — a save in
/// place, a save by rename, a new file. FSEvents tells us; no timer polls the disk, so an
/// idle app is not woken every few seconds just to find that nothing changed.
final class FolderWatch {
  private var stream: FSEventStreamRef?
  private let changed: () -> Void
  init?(_ folder: URL, latency: Double = 0.3, changed: @escaping () -> Void) {
    self.changed = changed
    var ctx = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
    ctx.info = Unmanaged.passUnretained(self).toOpaque()
    let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
      guard let info else { return }
      Unmanaged<FolderWatch>.fromOpaque(info).takeUnretainedValue().changed()
    }
    guard let s = FSEventStreamCreate(nil, callback, &ctx, [folder.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                      latency, FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)) else { return nil }
    FSEventStreamSetDispatchQueue(s, .main)
    guard FSEventStreamStart(s) else { FSEventStreamInvalidate(s); FSEventStreamRelease(s); return nil }
    stream = s
  }
  deinit { if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s) } }
}

enum Paths {
  static let home = FileManager.default.homeDirectoryForCurrentUser
  /// The checkout this app was built from (written into Info.plist by build.sh).
  static let root: URL = {
    if let p = Bundle.main.object(forInfoDictionaryKey: "WDRoot") as? String, !p.isEmpty { return URL(fileURLWithPath: p) }
    return home.appendingPathComponent("Developer/work-dashboard")
  }()
  static let web = root.appendingPathComponent("web")
  static let scripts = root.appendingPathComponent("scripts")
  static let config: URL = {
    if let p = ProcessInfo.processInfo.environment["WD_CONFIG"] { return URL(fileURLWithPath: p) }
    return home.appendingPathComponent(".config/work-dashboard/config.json")
  }()
  static let support = home.appendingPathComponent("Library/Application Support/Work Dashboard")   // the old name, kept: your saved layout lives here
  static let state = support.appendingPathComponent("state.json")
  static let cache = home.appendingPathComponent("Library/Caches/work-dashboard")
}

/// Runs a process with a hard timeout and ALWAYS calls `done` once, on the main queue.
/// - The child gets its own process group (via perl's setpgrp), so a timeout stops the
///   whole tree — gh, curl, kubectl or basecamp that the script started — not just bash.
/// - stdout and stderr are drained as they arrive, so a chatty stderr can't stall the
///   child, and a grandchild that keeps a pipe open can't block completion.
func runProcess(_ exe: String, _ args: [String], env: [String: String] = [:], timeout: Double,
                done: @escaping (_ out: String, _ err: String, _ status: Int32) -> Void) {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
  p.arguments = ["-e", "setpgrp(0,0); exec { $ARGV[0] } @ARGV or die \"cannot run $ARGV[0]: $!\\n\"", exe] + args
  var e = ProcessInfo.processInfo.environment
  env.forEach { e[$0.key] = $0.value }
  p.environment = e
  let out = Pipe(), err = Pipe()
  p.standardOutput = out; p.standardError = err
  let lock = NSLock()
  var outData = Data(), errData = Data()
  out.fileHandleForReading.readabilityHandler = { h in
    let d = h.availableData
    if d.isEmpty { h.readabilityHandler = nil } else { lock.lock(); outData.append(d); lock.unlock() }
  }
  err.fileHandleForReading.readabilityHandler = { h in
    let d = h.availableData
    if d.isEmpty { h.readabilityHandler = nil } else { lock.lock(); errData.append(d); lock.unlock() }
  }
  var finished = false   // touched on the main queue only
  let finish: (Int32) -> Void = { status in
    DispatchQueue.main.async {
      guard !finished else { return }
      finished = true
      out.fileHandleForReading.readabilityHandler = nil
      err.fileHandleForReading.readabilityHandler = nil
      lock.lock(); let o = outData, e2 = errData; lock.unlock()
      done(String(decoding: o, as: UTF8.self), String(decoding: e2, as: UTF8.self), status)
    }
  }
  // give the pipes a moment to deliver their last bytes after the child exits
  p.terminationHandler = { proc in
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { finish(proc.terminationStatus) }
  }
  do { try p.run() } catch {
    out.fileHandleForReading.readabilityHandler = nil; err.fileHandleForReading.readabilityHandler = nil
    let msg = "could not start \(exe): \(error)"
    DispatchQueue.main.async { done("", msg, -1) }   // the same queue as every other answer
    return
  }
  let pgid = p.processIdentifier
  DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
    guard p.isRunning else { return }
    kill(-pgid, SIGTERM)
    DispatchQueue.global().asyncAfter(deadline: .now() + 3) { kill(-pgid, SIGKILL); finish(124) }
  }
}

struct Collector {
  let name: String
  let exe: String
  let script: String
  let every: TimeInterval
  var timeout: Double = 120
}

final class Store {
  static let shared = Store()

  private(set) var config: [String: Any] = [:]
  private(set) var configText = "{}"
  private(set) var state: [String: Any] = [:]
  private(set) var data: [String: String] = [:]      // collector name → JSON text
  private(set) var updated: [String: Date] = [:]
  /// Why a collector's last run didn't replace its data (for the self-test): failed, or offline.
  private(set) var failures: [String: String] = [:]
  private var running = Set<String>()
  private var timers: [Timer] = []
  /// Called on the main thread whenever something changes: ("data", name) / ("config", "") / ("state", "").
  var onChange: [(String, String) -> Void] = []

  /// A collector exits with this (EX_TEMPFAIL) when it can't look right now (no
  /// network): the last good result stays, instead of an error replacing it.
  static let keepLast: Int32 = 75

  let collectors: [Collector] = [
    Collector(name: "health",   exe: "/bin/bash", script: "health.sh",    every: 60),
    Collector(name: "local",    exe: "/bin/bash", script: "local.sh",     every: 60),
    Collector(name: "github",   exe: "/bin/bash", script: "github.sh",    every: 180),
    Collector(name: "linear",   exe: "/bin/bash", script: "linear.sh",    every: 180),
    Collector(name: "basecamp", exe: "/bin/bash", script: "basecamp.sh",  every: 300),
    Collector(name: "sessions", exe: "/usr/bin/python3", script: "sessions.py", every: 120),
    Collector(name: "today",    exe: "/bin/bash", script: "today.sh",     every: 600),
    // writes the standup with Claude once a workday morning; every other run reads the cache
    Collector(name: "standup",  exe: "/bin/bash", script: "standup.sh",   every: 900, timeout: 300),
  ]

  func start() {
    try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: Paths.cache, withIntermediateDirectories: true)
    firstRunConfig(); loadConfig(); loadState(); watchConfig()
    // last good results first — the screen is never blank
    for c in collectors {
      if let s = try? String(contentsOf: Paths.cache.appendingPathComponent("\(c.name).json"), encoding: .utf8) { data[c.name] = s }
    }
    collectors.forEach { run($0) }
    scheduleTimers()
    onChange.append { [weak self] kind, _ in if kind == "config" { self?.scheduleTimers() } }
  }

  /// One timer per collector; config `intervals` (seconds) overrides the defaults
  /// and applies as soon as the config is saved.
  private func scheduleTimers() {
    timers.forEach { $0.invalidate() }
    timers = collectors.map { c in
      let every = interval(of: c)
      let t = Timer(timeInterval: every, repeats: true) { [weak self] _ in self?.run(c) }
      t.tolerance = every * 0.1
      RunLoop.main.add(t, forMode: .common)
      return t
    }
  }

  /// Seconds between runs: config `intervals` overrides the default, never under 10.
  func interval(of c: Collector) -> TimeInterval {
    // one bad value (e.g. "180" as a string) must not drop every other override
    let v = (config["intervals"] as? [String: Any])?[c.name]
    return max(10, (v as? NSNumber)?.doubleValue ?? Double(v as? String ?? "") ?? c.every)
  }

  /// Run every collector now (wake, network back, manual refresh), or just the stale ones.
  func refreshAll(onlyOlderThan age: TimeInterval = 0) {
    for c in collectors where Date().timeIntervalSince(updated[c.name] ?? .distantPast) > age { run(c) }
  }

  /// Run one collector by name now (e.g. "local" right after starting the DB proxy).
  func run(named name: String, env: [String: String] = [:]) { if let c = collectors.first(where: { $0.name == name }) { run(c, env: env) } }

  func run(_ c: Collector, env: [String: String] = [:]) {
    guard !running.contains(c.name) else { return }
    running.insert(c.name)
    runProcess(c.exe, [Paths.scripts.appendingPathComponent(c.script).path],
               env: env.merging(["WD_CONFIG": Paths.config.path]) { $1 }, timeout: c.timeout) { [weak self] out, err, status in
      guard let self else { return }
      self.running.remove(c.name)
      let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
      if status == Store.keepLast { self.failures[c.name] = "offline, so it kept its last result"; return }   // the collector asks to keep the last good result
      guard status == 0, text.hasPrefix("{"), (try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil else {
        NSLog("WorkDashboard collector %@ failed (%d): %@", c.name, status, String(err.prefix(300)))
        let why = err.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last ?? ""
        self.failures[c.name] = status == 124 ? "timed out after \(Int(c.timeout)) s" : status != 0 ? "exited with \(status)\(why.isEmpty ? "" : ": \(why.prefix(160))")" : "printed no JSON object"
        return   // keep the last good result
      }
      self.failures[c.name] = nil
      self.data[c.name] = text
      self.updated[c.name] = Date()
      try? text.write(to: Paths.cache.appendingPathComponent("\(c.name).json"), atomically: true, encoding: .utf8)
      self.keepForTheDay(c.name, text)
      self.emit("data", c.name)
    }
  }

  func setData(_ name: String, _ json: String) {   // native sources (calendar)
    data[name] = json; updated[name] = Date(); keepForTheDay(name, json); emit("data", name)
  }

  // ── the day's record, for the standup ──
  /// The sources the Today column is built from, kept per day (days/<YYYY-MM-DD>/<name>.json,
  /// the configured timezone's day) so standup.sh can write up the previous working day
  /// from what Manara saw. Three weeks are kept. (Claude sessions are read from the
  /// transcripts themselves: standup-sessions.sh.)
  private static let dayKept: Set<String> = ["today", "linear", "calendar"]
  private var lastPrune = ""
  private func keepForTheDay(_ name: String, _ json: String) {
    guard Store.dayKept.contains(name) else { return }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
    f.timeZone = (config["timezone"] as? String).flatMap(TimeZone.init(identifier:)) ?? .current
    let day = f.string(from: Date()), days = Paths.cache.appendingPathComponent("days")
    let dir = days.appendingPathComponent(day)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try? json.write(to: dir.appendingPathComponent("\(name).json"), atomically: true, encoding: .utf8)
    guard lastPrune != day else { return }
    lastPrune = day
    let oldest = f.string(from: Date().addingTimeInterval(-21 * 86400))
    for d in (try? FileManager.default.contentsOfDirectory(atPath: days.path)) ?? [] where d < oldest {
      try? FileManager.default.removeItem(at: days.appendingPathComponent(d))
    }
  }

  // ── config (the user's file; the app only writes it from Settings) ──
  /// Only on the very first launch: start from the example, private to you (0600).
  private func firstRunConfig() {
    let fm = FileManager.default
    guard !fm.fileExists(atPath: Paths.config.path) else { return }
    try? fm.createDirectory(at: Paths.config.deletingLastPathComponent(), withIntermediateDirectories: true,
                            attributes: [.posixPermissions: 0o700])
    try? fm.copyItem(at: Paths.root.appendingPathComponent("config.example.json"), to: Paths.config)
    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.config.path)
  }

  /// A missing, empty or half-written file (an editor mid-save) keeps the last good config.
  func loadConfig() {
    guard let text = try? String(contentsOf: Paths.config, encoding: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], !obj.isEmpty else { return }
    config = obj; configText = text
  }

  func saveConfig(_ text: String) -> String? {
    guard let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return "That is not valid JSON." }
    guard !obj.isEmpty else { return "The settings are empty — nothing was saved." }
    do {
      try text.write(to: Paths.config, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.config.path)
    } catch { return "Could not save: \(error.localizedDescription)" }
    let before = config
    loadConfig(); emit("config", ""); refreshIfSourcesChanged(from: before)
    return nil
  }

  /// Settings saves on every change; a new theme or widget size must not re-run
  /// every collector (GitHub, kubectl, Basecamp…). Only the keys the collectors
  /// read do; the keys listed here are read only by the app and its pages.
  private static let uiOnlyKeys: Set<String> = ["appearance", "calendar", "dashboard", "widgets", "notifications", "textScale", "workday",
                                                   "showConnections", "kubeProdReminder", "devTestPhone", "incidents", "_readme"]
  private func refreshIfSourcesChanged(from before: [String: Any]) {
    let sources = { (c: [String: Any]) in NSDictionary(dictionary: c.filter { !Store.uiOnlyKeys.contains($0.key) }) }
    if !sources(before).isEqual(sources(config)) { refreshAll() }
  }

  /// Watch the config's FOLDER, not the file: editors that save by renaming replace
  /// the file, which would silently end a file watch. FSEvents also sees in-place
  /// writes, so nothing polls. Debounced, so a save is one reload.
  private var configReload: DispatchWorkItem?
  private var configWatch: FolderWatch?
  var watchingConfig: Bool { configWatch != nil }
  private func watchConfig() {
    let folder = Paths.config.deletingLastPathComponent()
    let watch = FolderWatch(folder) { [weak self] in
      guard let self else { return }
      self.configReload?.cancel()
      let w = DispatchWorkItem { [weak self] in
        guard let self else { return }
        let before = self.configText, old = self.config
        self.loadConfig()
        if self.configText != before { self.emit("config", ""); self.refreshIfSourcesChanged(from: old) }
      }
      self.configReload = w
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }
    // folder not there yet, or no FSEvents: try again shortly
    guard FileManager.default.fileExists(atPath: folder.path), let watch else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.watchConfig() }; return
    }
    configWatch = watch
  }

  // ── local state: issue colours, mutes, widget frames, text size, seen alerts ──
  func loadState() {
    if let d = try? Data(contentsOf: Paths.state), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { state = obj }
  }
  func setState(_ key: String, _ value: Any?) {
    state[key] = value
    if let d = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
      try? d.write(to: Paths.state, options: .atomic)
    }
    emit("state", key)
  }
  var stateText: String {
    (try? JSONSerialization.data(withJSONObject: state)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
  }

  private func emit(_ kind: String, _ name: String) { onChange.forEach { $0(kind, name) } }
}
