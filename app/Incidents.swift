// One click from an incident to an investigation: opens Terminal in your
// workspace and starts Claude Code with the investigation command and the
// incident's details. The command runs read-only by its own rules; this app only
// starts it. Config `incidents`: cwd (default ~, your home folder),
// command (default /incident-investigation), claude (default ~/.local/bin/claude),
// terminal (see Terminal.swift),
// permissionMode (default "auto": it runs without stopping for approval, and Claude
// Code's own check still blocks risky actions; "default" asks at each step;
// "bypassPermissions" skips every check — Claude Code advises that only for sandboxes).

import Cocoa

enum Investigator {
  /// What a start wrote, and where it would open (the self-test checks it).
  struct Launch { let script: URL; let promptFile: URL; let terminal: URL; let cwd: String; let mode: String; let body: String }

  /// dryRun: write the script and prompt file, but open no terminal (Settings → Check the app).
  @discardableResult
  static func start(subject: String, dryRun: Bool = false) -> Launch? {
    let cfg = Store.shared.config["incidents"] as? [String: Any] ?? [:]
    let fm = FileManager.default
    var cwd = ((cfg["cwd"] as? String) ?? "~").expandingTilde
    if !fm.fileExists(atPath: cwd) { cwd = NSHomeDirectory() }
    let claude = ((cfg["claude"] as? String) ?? "~/.local/bin/claude").expandingTilde
    let command = (cfg["command"] as? String) ?? "/incident-investigation"
    let mode = ["default", "auto", "acceptEdits", "plan", "bypassPermissions"].contains(cfg["permissionMode"] as? String ?? "")
      ? cfg["permissionMode"] as! String : "auto"
    let terminal = Term.app

    // The details come from monitoring data, so they are never put in the script:
    // the script reads them from a file as one argument, which the shell can't run.
    let one = subject.components(separatedBy: .newlines).joined(separator: " ")
    let prompt = "\(command) \(String(one.prefix(600)))"
    let dir = Term.folder("investigate")
    let stamp = "\(dryRun ? "dryrun-" : "")\(Int(Date().timeIntervalSince1970))"
    let promptFile = dir.appendingPathComponent("prompt-\(stamp).txt")
    let script = dir.appendingPathComponent("investigate-\(stamp).command")
    let body = """
    #!/bin/zsh -l
    cd \(quote(cwd)) || exit 1
    printf '\\nStarting an incident investigation in Claude (read-only).\\n\\n'
    exec \(quote(claude)) --permission-mode \(mode) "$(cat \(quote(promptFile.path)))"

    """
    do { try prompt.write(to: promptFile, atomically: true, encoding: .utf8) }
    catch { NSLog("WorkDashboard investigate: %@", "\(error)"); return nil }
    guard Term.write(body, to: script) else { return nil }
    let launch = Launch(script: script, promptFile: promptFile, terminal: terminal, cwd: cwd, mode: mode, body: body)
    if dryRun { return launch }
    Term.open(script, in: terminal)
    return launch
  }

  private static func quote(_ s: String) -> String { Term.quote(s) }
}

private extension String {
  var expandingTilde: String { (self as NSString).expandingTildeInPath }
}
