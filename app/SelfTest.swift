// Settings → Check the app: a pass/fail list of what the app needs to work, one
// plain line per check. Every check only looks, or puts back what it touched (a
// widget is moved 1 pt and back; Investigate is built in dry-run and deleted).
// Unattended: if ~/Library/Caches/work-dashboard/selftest-request exists at launch,
// it runs a minute later (the collectors have answered by then), writes
// selftest-result.json next to it and deletes the request.

import Cocoa
import EventKit
import UserNotifications
import WebKit

final class SelfTest {
  struct Item { let group: String; let name: String; let ok: Bool; let line: String }
  private static let order = ["Data", "Config", "Displays", "Dashboard", "Widgets", "Keychain", "Permissions", "Investigate", "DB proxy", "App"]
  private var items: [Item] = []
  private let app: AppDelegate
  private init(_ app: AppDelegate) { self.app = app }

  static func run(_ app: AppDelegate, done: @escaping ([Item]) -> Void) {
    let t = SelfTest(app)   // kept alive by the closures below until done
    t.syncChecks()
    t.pageTheme {
      t.notifications {
        t.widgets {
          done(t.items.sorted { (order.firstIndex(of: $0.group) ?? 99) < (order.firstIndex(of: $1.group) ?? 99) })
        }
      }
    }
  }

  static func json(_ items: [Item]) -> String {
    let obj: [String: Any] = ["at": ISO8601DateFormatter().string(from: Date()), "passed": items.filter(\.ok).count, "failed": items.filter { !$0.ok }.count,
                              "checks": items.map { ["group": $0.group, "name": $0.name, "ok": $0.ok, "line": $0.line] }]
    return (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
  }

  static func runIfRequested(_ app: AppDelegate) {
    let request = Paths.cache.appendingPathComponent("selftest-request")
    guard FileManager.default.fileExists(atPath: request.path) else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
      run(app) { items in
        try? json(items).write(to: Paths.cache.appendingPathComponent("selftest-result.json"), atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: request)
      }
    }
  }

  private func add(_ group: String, _ name: String, _ ok: Bool, _ line: String) { items.append(Item(group: group, name: name, ok: ok, line: line)) }
  private static func size(_ r: NSRect) -> String { "\(Int(r.width))×\(Int(r.height)) at \(Int(r.minX)),\(Int(r.minY))" }
  private static func ago(_ s: TimeInterval) -> String { s < 90 ? "\(Int(s)) s" : s < 5400 ? "\(Int(s / 60)) min" : "\(Int(s / 3600)) h" }

  private func syncChecks() {
    let store = Store.shared, fm = FileManager.default
    // ── every collector: fresh, valid JSON, no error inside ──
    for c in store.collectors {
      let every = store.interval(of: c)
      let cached = Paths.cache.appendingPathComponent("\(c.name).json")
      let at = store.updated[c.name] ?? (try? cached.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
      let why = store.failures[c.name].map { " — last run \($0)" } ?? ""
      guard let text = store.data[c.name] else { add("Data", c.name, false, "No data yet\(why)."); continue }
      guard let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { add("Data", c.name, false, "Its data is not valid JSON\(why)."); continue }
      let age = at.map { Date().timeIntervalSince($0) } ?? .infinity
      if let e = obj["error"] { add("Data", c.name, false, "Says: \(String(describing: e).prefix(160))"); continue }
      if age >= 3 * every { add("Data", c.name, false, "Stale: \(age.isFinite ? SelfTest.ago(age) : "no time") old, it runs every \(Int(every)) s\(why)."); continue }
      add("Data", c.name, true, "Fresh: \(SelfTest.ago(age)) old (every \(Int(every)) s)\(why).")
    }
    // ── config and theme ──
    let text = try? String(contentsOf: Paths.config, encoding: .utf8)
    let parses = text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } is [String: Any]
    add("Config", "Config file", parses && !store.config.isEmpty,
        parses ? "\(Paths.config.path) loads (\(store.config.count) sections)." : "\(Paths.config.path) is missing or not valid JSON; the app keeps the last good one.")
    let theme = Backdrop.theme, kind = (store.config["appearance"] as? [String: Any])?["glass"] as? String ?? "smoked"
    let known = ["graphite", "glass", "midnight", "light"].contains(theme)
    add("Config", "Theme", known, known ? "Resolves to \(theme)\(theme == "glass" ? " (\(kind))" : "")." : "\"\(theme)\" is not a theme; it shows as Graphite.")
    // ── displays ──
    let screens = NSScreen.screens
    add("Displays", "Displays", !screens.isEmpty, screens.isEmpty ? "No display found." : screens.enumerated().map { i, s in
      "\(s.localizedName) \(Int(s.frame.width))×\(Int(s.frame.height))\(i == 0 ? " (main)" : "")" }.joined(separator: " · "))
    // ── the dashboard window ──
    if let w = app.dashboard.window {
      let want = Dashboard.preferredScreen()
      let on = w.screen
      add("Dashboard", "On its display", on != nil && on == want, on == nil ? "The window is on no display."
          : on == want ? "On \(on!.localizedName), as Settings asks." : "On \(on!.localizedName), but Settings asks for \(want?.localizedName ?? "a missing display"). Use Settings → Placement to move it.")
      let f = w.frame, whole = screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(f) }
      add("Dashboard", "Whole on one display", whole != nil, whole != nil ? "\(app.dashboard.isFullScreen ? "Full screen" : "Window") \(SelfTest.size(f)), inside \(whole!.localizedName)."
          : "\(SelfTest.size(f)) straddles \(screens.filter { $0.frame.intersects(f) }.map(\.localizedName).joined(separator: " and ")) — it is stuck between displays.")
      let (bg, chrome) = Backdrop.windowLook(theme: theme, glass: kind)
      let same = { (a: NSColor?, b: NSColor) -> Bool in
        guard let a = a?.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.01 && abs(a.greenComponent - b.greenComponent) < 0.01 && abs(a.blueComponent - b.blueComponent) < 0.01
      }
      let looks = same(w.backgroundColor, bg) && w.appearance?.name == chrome
      add("Dashboard", "Window matches the theme", looks, looks ? "Background and \(chrome == .aqua ? "light" : "dark") window chrome match \(theme)."
          : "The window's background or chrome doesn't match \(theme) (chrome \(w.appearance?.name.rawValue ?? "none")).")
    } else { add("Dashboard", "Window", false, "There is no dashboard window (no display when the app started?).") }
    // ── keychain: presence only, never the value ──
    for (name, key) in [("Linear", "linear"), ("Better Stack", "betterstack")] {
      guard let svc = (store.config[key] as? [String: Any])?["keychainService"] as? String, !svc.isEmpty else { add("Keychain", name, true, "Not configured (optional)."); continue }
      let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: svc, kSecMatchLimit as String: kSecMatchLimitOne, kSecReturnAttributes as String: true]
      let st = SecItemCopyMatching(q as CFDictionary, nil)
      add("Keychain", name, st == errSecSuccess, st == errSecSuccess ? "Item \"\(svc)\" is in the Keychain."
          : st == errSecItemNotFound ? "No Keychain item \"\(svc)\": security add-generic-password -s '\(svc)' -a token -w" : "Couldn't look up \"\(svc)\" (\(st)).")
    }
    // ── calendar (status only: never prompts) ──
    let cal = EKEventStore.authorizationStatus(for: .event)
    add("Permissions", "Calendar", cal == .fullAccess, cal == .fullAccess ? "Full access: meetings and reminders work."
        : "Not allowed (\(cal.rawValue)): System Settings → Privacy & Security → Calendars → Manara.")
    // ── Investigate, built but not opened ──
    let marker = "selftest $(touch /tmp/wd-selftest-pwned) `id` 'quote'"
    if let l = Investigator.start(subject: marker, dryRun: true) {
      let cfg = store.config["incidents"] as? [String: Any] ?? [:]
      let iTerm = "/Applications/iTerm.app"
      let wantTerm = (cfg["terminal"] as? String).map { ($0 as NSString).expandingTildeInPath } ?? (fm.fileExists(atPath: iTerm) ? iTerm : "/System/Applications/Utilities/Terminal.app")
      let wantMode = cfg["permissionMode"] as? String ?? "auto"
      let prompt = (try? String(contentsOf: l.promptFile, encoding: .utf8)) ?? ""
      let command = cfg["command"] as? String ?? "/incident-investigation"
      var problems: [String] = []
      if l.terminal.path != wantTerm { problems.append("opens \(l.terminal.lastPathComponent), not \((wantTerm as NSString).lastPathComponent)") }
      if !fm.fileExists(atPath: l.terminal.path) { problems.append("\(l.terminal.path) is not installed") }
      if !l.body.contains("cd '\(l.cwd)'") { problems.append("doesn't cd into \(l.cwd)") }
      if l.cwd != ((cfg["cwd"] as? String ?? "~") as NSString).expandingTildeInPath { problems.append("incidents.cwd is missing, so it opens in \(l.cwd)") }
      if !l.body.contains("--permission-mode \(wantMode)") { problems.append("permission mode isn't \(wantMode)") }
      if l.body.contains("selftest") || l.body.contains("touch") { problems.append("the subject leaked into the script") }
      if prompt != "\(command) \(marker)" { problems.append("the prompt file doesn't hold the command and subject") }
      let claude = l.body.components(separatedBy: "exec '").dropFirst().first?.components(separatedBy: "'").first ?? ""
      if !fm.isExecutableFile(atPath: claude) { problems.append("Claude isn't at \(claude)") }
      add("Investigate", "Launch script", problems.isEmpty, problems.isEmpty
          ? "Opens \(l.terminal.deletingPathExtension().lastPathComponent) in \(l.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~")), runs \(command) in \(l.mode) mode; the subject goes only through the prompt file."
          : problems.joined(separator: "; ") + ".")
      try? fm.removeItem(at: l.script); try? fm.removeItem(at: l.promptFile)
    } else { add("Investigate", "Launch script", false, "Couldn't write the launch script to \(Paths.cache.path)/investigate.") }
    // ── DB proxy start command: on PATH, not run ──
    if let cmd = (store.config["dbProxy"] as? [String: Any])?["startCommand"] as? String, !cmd.isEmpty {
      let exe = (String(cmd.split(separator: " ").first ?? "") as NSString).expandingTildeInPath
      let path = ["\(NSHomeDirectory())/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]   // the button's PATH (Pages.swift)
      let found = exe.hasPrefix("/") ? (fm.isExecutableFile(atPath: exe) ? exe : nil) : path.map { "\($0)/\(exe)" }.first { fm.isExecutableFile(atPath: $0) }
      add("DB proxy", "Start command", found != nil, found.map { "\(exe) resolves to \($0.replacingOccurrences(of: NSHomeDirectory(), with: "~"))." } ?? "\(exe) is not on the PATH the button uses.")
    } else { add("DB proxy", "Start command", true, "Not configured (optional).") }
    // ── Sign in: the script runs the login's fix as written, and nothing else ──
    if let file = SignIn.start(name: "Google Cloud", fix: "gcloud auth login", dryRun: true) {
      let body = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
      let ok = body.contains("if gcloud auth login; then") && fm.isExecutableFile(atPath: file.path)
      add("Sign in", "Login script", ok, ok ? "An expired login opens \(Term.app.deletingPathExtension().lastPathComponent) and runs its fix, then Manara looks again every 5 s."
                                            : "The sign-in script wasn't written as expected.")
      try? fm.removeItem(at: file)
    } else { add("Sign in", "Login script", false, "Couldn't write the sign-in script to \(Paths.cache.path)/signin.") }
    // ── the app's own machinery ──
    add("App", "Hot reload", Pages.shared.watchingWeb && store.watchingConfig,
        "\(Pages.shared.watchingWeb ? "Watching" : "NOT watching") web/ · \(store.watchingConfig ? "watching" : "NOT watching") the config folder.")
    add("App", "Menu bar", app.statusBar.isInstalled, app.statusBar.isInstalled ? "The status item is in the menu bar." : "The status item is missing from the menu bar.")
    let keys: [UInt32: String] = [1: "⌃⌥⌘D", 2: "⌥⌘K"]
    let taken = keys.filter { hotKeyStatus[$0.key] != noErr }.map(\.value).sorted()
    add("App", "Shortcuts", taken.isEmpty, taken.isEmpty ? "⌃⌥⌘D and ⌥⌘K are registered." : "Not registered (taken by another app?): \(taken.joined(separator: ", ")).")
  }

  /// The page and the window agree on the theme.
  private func pageTheme(_ next: @escaping () -> Void) {
    guard let page = app.dashboard.window?.contentView?.subviews.first(where: { $0 is PageView }) as? PageView else { next(); return }
    page.evaluateJavaScript("document.documentElement.dataset.theme + '|' + (document.documentElement.dataset.glass || '')") { [self] v, _ in
      let t = Backdrop.theme, got = (v as? String ?? "").split(separator: "|").first.map(String.init) ?? ""
      add("Dashboard", "Page theme", got == t, got == t ? "The page draws \(t) too." : "The page draws \(got.isEmpty ? "nothing yet" : got), the window \(t).")
      next()
    }
  }

  private func notifications(_ next: @escaping () -> Void) {
    UNUserNotificationCenter.current().getNotificationSettings { s in
      DispatchQueue.main.async { [self] in
        let ok = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
        add("Permissions", "Notifications", ok, ok ? "Allowed\(s.alertSetting == .enabled ? ", with banners" : ", but banners are off")."
            : s.authorizationStatus == .notDetermined ? "Not answered yet: macOS is asking (a rebuild asks again) — click Allow on its prompt."
            : "Not allowed: System Settings → Notifications → Manara.")
        next()
      }
    }
  }

  /// Each enabled widget: its window, fixed size, whole on a display, its layer — and a
  /// move by 1 pt and back, the same path Settings → Placement uses. Its saved place is put back.
  private func widgets(_ next: @escaping () -> Void) {
    let w = app.widgets
    let on = w.specs.filter { $0["enabled"] as? Bool ?? true }
    guard !on.isEmpty else { add("Widgets", "Widgets", true, "No widget is turned on."); next(); return }
    let savedFrames = Store.shared.state["widgetFrames"]
    for s in on {
      let id = s["id"] as? String ?? "?", name = Widgets.names[s["type"] as? String ?? ""] ?? id
      guard let win = w.windows[id] else { add("Widgets", name, false, "Turned on, but it has no window."); continue }
      var bad: [String] = []
      let want = Widgets.size(of: s)
      if win.frame.size != want { bad.append("is \(Int(win.frame.width))×\(Int(win.frame.height)), not \(Int(want.width))×\(Int(want.height))") }
      let home = NSScreen.screens.first { $0.visibleFrame.insetBy(dx: -1, dy: -1).contains(win.frame) }
      if home == nil { bad.append("isn't whole inside one display (\(SelfTest.size(win.frame)))") }
      let level = w.arranging ? .floating : Widgets.level(of: s)
      if win.level != level { bad.append("sits at level \(win.level.rawValue), not \(level.rawValue) for \(s["layer"] as? String ?? "desktop")") }
      if !win.isVisible { bad.append("is not showing") }
      let o = win.frame.origin
      w.move(id, to: NSPoint(x: o.x + 1, y: o.y + 1))
      let moved = win.frame.origin == NSPoint(x: o.x + 1, y: o.y + 1)
      w.move(id, to: o)
      if !moved || win.frame.origin != o { bad.append("didn't move by 1 pt and back (now \(Int(win.frame.minX)),\(Int(win.frame.minY)))") }
      add("Widgets", name, bad.isEmpty, bad.isEmpty ? "\(Int(want.width))×\(Int(want.height)) on \(home?.localizedName ?? "?") at \(Int(o.x)),\(Int(o.y)); moved 1 pt and back." : "It " + bad.joined(separator: "; ") + ".")
    }
    // the moves above schedule a save (0.6 s): put the remembered places back exactly as they were
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { Store.shared.setState("widgetFrames", savedFrames); next() }
  }
}
