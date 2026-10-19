// Running a short script in your terminal app, for the two things that need you
// at a prompt: Investigate (Incidents.swift) and Sign in. Config `terminal` (an app
// path; `incidents.terminal` is still read) — default iTerm2 when it's installed,
// otherwise Terminal.

import Cocoa

enum Term {
  static var app: URL {
    let cfg = Store.shared.config
    let set = (cfg["terminal"] as? String) ?? ((cfg["incidents"] as? [String: Any])?["terminal"] as? String)
    let iTerm = "/Applications/iTerm.app"
    return URL(fileURLWithPath: set.map { ($0 as NSString).expandingTildeInPath }
               ?? (FileManager.default.fileExists(atPath: iTerm) ? iTerm : "/System/Applications/Utilities/Terminal.app"))
  }

  /// A private folder under the cache for one kind of script, with yesterday's cleared out.
  static func folder(_ name: String) -> URL {
    let dir = Paths.cache.appendingPathComponent(name)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    cleanup(dir)
    return dir
  }

  /// Write `body` as an executable .command script.
  static func write(_ body: String, to script: URL) -> Bool {
    do {
      try body.write(to: script, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
      return true
    } catch { NSLog("WorkDashboard terminal: %@", "\(error)"); return false }
  }

  static func open(_ script: URL, in terminal: URL = Term.app) {
    let conf = NSWorkspace.OpenConfiguration()
    conf.activates = true
    NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: conf) { _, err in
      if let err { NSLog("WorkDashboard terminal: %@", "\(err)") }
    }
  }

  static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

  /// Keep a day of scripts (handy to rerun), then let them go.
  private static func cleanup(_ dir: URL) {
    let fm = FileManager.default
    for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
      if let t = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, Date().timeIntervalSince(t) > 86400 {
        try? fm.removeItem(at: f)
      }
    }
  }
}

/// One click on an expired login: your terminal runs that login's fix (for Google
/// Cloud: `gcloud auth login`, then dbProxy.startCommand), so all that's left is
/// choosing your account in the browser. The fix comes from the local collector,
/// which builds it from your config — never from the page.
enum SignIn {
  private static var watch: Timer?

  /// The fix for a login that is expired right now, if any.
  static func fix(for name: String) -> String? {
    guard let text = Store.shared.data["local"], let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
          let row = (obj["logins"] as? [[String: Any]])?.first(where: { $0["name"] as? String == name }),
          row["ok"] as? Bool == false, let fix = row["fix"] as? String, !fix.isEmpty else { return nil }
    return fix
  }

  static func script(name: String, fix: String) -> String {
    """
    #!/bin/zsh -l
    export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
    printf '\\nSigning in to %s. Your browser opens: choose your account and allow access.\\n\\n' \(Term.quote(name))
    if \(fix); then
      printf '\\nSigned in. Manara picks it up in a few seconds; you can close this window.\\n'
      sleep 4; exit 0
    fi
    printf '\\nThat didn'"'"'t finish. Run it again from Manara, or close this window.\\n'

    """
  }

  /// dryRun: write the script but open nothing (Settings → Check the app). Returns the script.
  @discardableResult
  static func start(name: String, fix override: String? = nil, dryRun: Bool = false) -> URL? {
    guard let fix = override ?? fix(for: name) else { return nil }
    let file = Term.folder("signin").appendingPathComponent("\(dryRun ? "dryrun-" : "")signin-\(Int(Date().timeIntervalSince1970)).command")
    guard Term.write(script(name: name, fix: fix), to: file) else { return nil }
    if dryRun { return file }
    Term.open(file)
    follow(name)
    return file
  }

  /// Look again every 5 s while you sign in (up to 4 min); once the login is good,
  /// twice more so a proxy that's starting shows up as running.
  private static func follow(_ name: String) {
    watch?.invalidate()
    let began = Date()
    watch = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { t in
      let store = Store.shared
      if fix(for: name) == nil {
        t.invalidate()
        store.run(named: "health")   // pod checks need the login too
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { store.run(named: "local") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { store.run(named: "local") }
      } else if Date().timeIntervalSince(began) > 240 { t.invalidate() }
      else { store.run(named: "local") }
    }
  }
}
