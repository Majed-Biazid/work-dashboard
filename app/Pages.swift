// Web pages (dashboard, widgets, quick tools, settings) and the one bridge they
// share. The bridge answers only this app's own local pages (file:// main frame);
// there is no server and no open port. Every command is read-only or local.

import Cocoa
import WebKit

/// A web view that takes the first click even when its window is not key
/// (desktop widgets never activate the app).
final class PageView: WKWebView {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  /// ⌥-drag moves any widget, anywhere on it.
  override func mouseDown(with event: NSEvent) {
    if event.modifierFlags.contains(.option), let w = window as? WidgetWindow {
      w.performDrag(with: event); return
    }
    super.mouseDown(with: event)
  }
}

final class Pages: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
  static let shared = Pages()
  private var views: [PageView] = []
  weak var app: AppDelegate?

  private var webStamp: Date = .distantPast
  private var webWatch: FolderWatch?
  var watchingWeb: Bool { webWatch != nil }

  override init() {
    super.init()
    Store.shared.onChange.append { [weak self] kind, name in self?.broadcast(kind, name) }
    webStamp = newestWebChange()
    // Edit a page in web/ and every open page reloads — no rebuild, no ⌘R. FSEvents
    // says when something there changed (it used to be a 1.5 s poll, waking the app
    // all day); only a file newer than the last reload reloads.
    webWatch = FolderWatch(Paths.web) { [weak self] in
      guard let self else { return }
      let t = self.newestWebChange()
      if t > self.webStamp { self.webStamp = t; self.reloadAll() }
    }
  }

  private func newestWebChange() -> Date {
    let fm = FileManager.default
    let files = (try? fm.contentsOfDirectory(at: Paths.web, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    return files.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max() ?? .distantPast
  }

  func make(_ page: String, query: [String: String] = [:]) -> PageView {
    let cfg = WKWebViewConfiguration()
    cfg.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "bridge")
    let v = PageView(frame: .zero, configuration: cfg)
    v.navigationDelegate = self
    v.setValue(false, forKey: "drawsBackground")
    v.isInspectable = true   // Safari → Develop → this Mac → the page, for customising
    var c = URLComponents(url: Paths.web.appendingPathComponent(page), resolvingAgainstBaseURL: false)
    if !query.isEmpty { c?.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
    v.loadFileURL(c?.url ?? Paths.web.appendingPathComponent(page), allowingReadAccessTo: Paths.web)
    views.append(v)
    return v
  }

  func forget(_ v: PageView) { views.removeAll { $0 === v } }
  func reloadAll() { views.forEach { $0.reload() } }

  /// Push a change to every page: WD.receive(kind, name, payload).
  func broadcast(_ kind: String, _ name: String) {
    let payload: String
    switch kind {
    case "data": payload = Store.shared.data[name] ?? "null"
    case "config": payload = Store.shared.configText
    default: payload = Store.shared.stateText
    }
    let js = "window.WD && WD.receive(\(jsString(kind)), \(jsString(name)), \(jsString(payload)))"
    views.forEach { $0.evaluateJavaScript(js) }
  }

  func send(_ js: String) { views.forEach { $0.evaluateJavaScript(js) } }

  // Never navigate away from our own pages; links open in the browser.
  func webView(_ v: WKWebView, decidePolicyFor action: WKNavigationAction,
               decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let url = action.request.url else { decisionHandler(.cancel); return }
    if url.isFileURL && url.standardizedFileURL.path.hasPrefix(Paths.web.standardizedFileURL.path + "/") { decisionHandler(.allow); return }
    if ["http", "https"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
    decisionHandler(.cancel)
  }

  // ── the bridge ──
  func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage,
                             replyHandler: @escaping (Any?, String?) -> Void) {
    guard message.frameInfo.isMainFrame, let pageURL = message.frameInfo.request.url, pageURL.isFileURL,
          pageURL.standardizedFileURL.path.hasPrefix(Paths.web.standardizedFileURL.path + "/"),
          let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else {
      replyHandler(nil, "refused"); return
    }
    // Sensitive commands only from the pages that need them: the clipboard and the
    // session search from Quick Tools, writing the config from Settings, Investigate
    // from the dashboard and the "What needs you" widget.
    let page = pageURL.lastPathComponent
    let onlyFrom: [String: Set<String>] = ["clipboard": ["palette.html"], "searchSessions": ["palette.html"],
                                           "saveConfig": ["settings.html"], "openConfig": ["settings.html"],
                                           "investigate": ["dashboard.html", "widget.html"], "enrichStandup": ["dashboard.html"], "proxy": ["dashboard.html"], "signIn": ["dashboard.html"],
                                           "dashboardPlace": ["settings.html"], "widgetMove": ["settings.html"], "selftest": ["settings.html"]]
    if let allowed = onlyFrom[cmd], !allowed.contains(page) { replyHandler(nil, "refused"); return }
    let store = Store.shared
    switch cmd {
    case "boot":   // everything a page needs on load
      let obj: [String: Any] = ["config": store.configText, "state": store.stateText, "data": store.data,
                                "updated": store.updated.mapValues { $0.timeIntervalSince1970 * 1000 }]
      replyHandler(String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8), nil)
    case "refresh":
      store.refreshAll(); Agenda.shared.refresh(); replyHandler(true, nil)
    case "enrichStandup":   // gather again and add what today's standup is missing (or write it, if there is none yet)
      store.run(named: "standup", env: ["WD_STANDUP_ENRICH": "1"]); replyHandler(true, nil)
    case "state":
      if let key = body["key"] as? String { store.setState(key, body["value"]) }
      replyHandler(true, nil)
    case "saveConfig":
      replyHandler(store.saveConfig(body["text"] as? String ?? ""), nil)
    case "open":
      if let s = body["url"] as? String, let u = safeURL(s) { NSWorkspace.shared.open(u) }
      if body["closePalette"] as? Bool == true { app?.palette.hide() }
      replyHandler(true, nil)
    case "openConfig":
      NSWorkspace.shared.open(Paths.config); replyHandler(true, nil)
    case "copy":
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(body["text"] as? String ?? "", forType: .string)
      replyHandler(true, nil)
    case "clipboard":
      // Read only when Quick Tools opens, never in the background; skip secrets.
      let pb = NSPasteboard.general
      let secret = (pb.types ?? []).contains { ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"].contains($0.rawValue) }
      replyHandler(secret ? "" : (pb.string(forType: .string) ?? ""), nil)
    case "searchSessions":
      let words = (body["query"] as? String ?? "").split(separator: " ").map(String.init).filter { !$0.isEmpty }
      guard !words.isEmpty else { replyHandler("[]", nil); return }
      runProcess("/usr/bin/python3", [Paths.scripts.appendingPathComponent("search_sessions.py").path] + words,
                 env: ["WD_CONFIG": Paths.config.path], timeout: 30) { out, err, st in
        st == 0 ? replyHandler(out.isEmpty ? "[]" : out, nil) : replyHandler(nil, String(err.prefix(200)))
      }
    case "status":
      app?.statusBar.update(body); replyHandler(true, nil)
    case "alertsActive":   // forget notified alerts that ended, so a repeat outage notifies again
      Notifier.shared.keepOnly(body["ids"] as? [String] ?? []); replyHandler(true, nil)
    case "notify":
      Notifier.shared.post(id: body["id"] as? String ?? UUID().uuidString, title: body["title"] as? String ?? "",
                           body: body["body"] as? String ?? "", url: body["url"] as? String,
                           investigate: body["investigate"] as? String)
      replyHandler(true, nil)
    case "proxy":   // check, or start the DB proxy with your own start command (dbProxy.startCommand)
      if body["action"] as? String == "start", let cmd = (store.config["dbProxy"] as? [String: Any])?["startCommand"] as? String, !cmd.isEmpty {
        runProcess("/bin/bash", ["-c", cmd], env: ["PATH": "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"], timeout: 60) { out, err, st in
          // the proxy needs a few seconds to open its ports: look again twice
          store.run(named: "local")
          DispatchQueue.main.asyncAfter(deadline: .now() + 4) { store.run(named: "local") }
          DispatchQueue.main.asyncAfter(deadline: .now() + 12) { store.run(named: "local") }
          let said = (out + err).trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last ?? ""
          replyHandler(["ok": st == 0, "said": String(said.prefix(200))], nil)
        }
      } else { store.run(named: "local"); replyHandler(["ok": true, "said": ""], nil) }
    case "signIn":   // an expired login: your terminal runs its fix (Terminal.swift)
      replyHandler(SignIn.start(name: body["name"] as? String ?? "") != nil, nil)
    case "investigate":   // one click: Terminal + Claude's incident investigation
      if let s = body["subject"] as? String, !s.isEmpty { Investigator.start(subject: s) }
      replyHandler(true, nil)
    case "palette":
      (body["show"] as? Bool ?? false) ? app?.palette.show(tool: body["tool"] as? String) : app?.palette.hide()
      replyHandler(true, nil)
    case "dashboard": app?.palette.hide(); app?.dashboard.show(); replyHandler(true, nil)
    case "displays":   // for Settings → Placement: every display and where each window is, in global points
      let rect = { (r: NSRect) -> [String: Double] in ["x": r.minX, "y": r.minY, "w": r.width, "h": r.height] }
      let names = NSScreen.screens.enumerated().map { i, s in
        ["name": s.localizedName, "builtin": s.localizedName.localizedCaseInsensitiveContains("built-in"), "main": i == 0,   // screens[0] has the menu bar
         "size": "\(Int(s.frame.width))×\(Int(s.frame.height))", "frame": rect(s.frame), "visible": rect(s.visibleFrame)] as [String: Any] }
      let widgets = (app?.widgets.windows ?? [:]).map { id, w in ["id": id, "frame": rect(w.frame), "screen": w.screen?.localizedName ?? ""] as [String: Any] }
      replyHandler(["screens": names, "current": app?.dashboard.window?.screen?.localizedName ?? "", "widgets": widgets,
                    "dashboard": app?.dashboard.window.map { rect($0.frame) } ?? [:],
                    "mode": app?.dashboard.isFullScreen == true ? "fullscreen" : "window"], nil)
    case "widgetMove":   // Settings → Placement: put a widget at a spot (global, bottom-left origin); it is remembered like a drag
      if let id = body["id"] as? String, let x = body["x"] as? Double, let y = body["y"] as? Double { app?.widgets.move(id, to: NSPoint(x: x, y: y)) }
      replyHandler(true, nil)
    case "dashboardPlace":   // Settings: go to the chosen display now, and/or switch full screen ↔ window
      if body["move"] as? Bool == true { app?.dashboard.moveToPreferredScreen() }
      if let m = body["mode"] as? String, (m == "fullscreen") != (app?.dashboard.isFullScreen == true) { app?.dashboard.toggleMode() }
      replyHandler(true, nil)
    case "windowMode":
      if body["toggle"] as? Bool == true { app?.dashboard.toggleMode() }
      replyHandler(app?.dashboard.isFullScreen == true ? "fullscreen" : "window", nil)
    case "settings":  app?.showSettings(); replyHandler(true, nil)
    case "selftest":   // Settings → Check the app: a pass/fail list, one plain line each
      guard let app else { replyHandler(nil, "no app"); return }
      SelfTest.run(app) { replyHandler(SelfTest.json($0), nil) }
    case "arrange":   // toggles (or sets "on"); "query" only asks. Replies whether arranging is on now.
      if body["query"] as? Bool != true { app?.widgets.setArranging(body["on"] as? Bool ?? !(app?.widgets.arranging ?? false)) }
      replyHandler(app?.widgets.arranging ?? false, nil)
    case "widgetFrame":
      app?.widgets.resetFrame(body["id"] as? String ?? ""); replyHandler(true, nil)
    default: replyHandler(nil, "unknown command \(cmd)")
    }
  }
}

/// Links the app will open: http(s), the macOS privacy settings pane, and local
/// documents (never an app, script or anything else that runs).
func safeURL(_ s: String) -> URL? {
  guard let u = s.hasPrefix("/") ? URL(fileURLWithPath: s) : URL(string: s) else { return nil }
  switch u.scheme ?? "" {
  case "http", "https": return u
  case "x-apple.systempreferences": return u.absoluteString.hasPrefix("x-apple.systempreferences:com.apple.preference.security") ? u : nil
  case "file": return ["html", "htm", "md", "txt", "pdf", "json", "png", "jpg"].contains(u.pathExtension.lowercased()) ? u : nil
  default: return nil
  }
}

func jsString(_ s: String) -> String {
  let d = try! JSONSerialization.data(withJSONObject: [s])
  let a = String(data: d, encoding: .utf8)!
  return String(a.dropFirst().dropLast())
}
