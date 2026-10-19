// The dashboard (its own full-screen Space), Quick Tools (a floating panel that
// never switches desktops), the menu-bar item, Settings, and global shortcuts.

import Cocoa
import Carbon

// ── dashboard ───────────────────────────────────────────────────────────────
final class Dashboard: NSObject, NSWindowDelegate {
  var window: NSWindow!
  /// "fullscreen" (its own Space) or "window" (a normal resizable window) — remembered.
  var mode: String {
    get { UserDefaults.standard.string(forKey: "dashboardMode") ?? "fullscreen" }
    set { UserDefaults.standard.set(newValue, forKey: "dashboardMode") }
  }
  private var pendingFullScreen = false

  /// The display it opens on: config `dashboard.display` — "builtin", "main" or a
  /// display's name as macOS shows it. A display that isn't connected falls back
  /// to the built-in one, then the main one.
  static func preferredScreen() -> NSScreen? {
    let want = ((Store.shared.config["dashboard"] as? [String: Any])?["display"] as? String) ?? "builtin"
    let builtin = NSScreen.screens.first { $0.localizedName.localizedCaseInsensitiveContains("built-in") }
    switch want {
    case "main": return NSScreen.main ?? NSScreen.screens.first
    case "builtin": return builtin ?? NSScreen.main ?? NSScreen.screens.first
    default: return NSScreen.screens.first { $0.localizedName == want } ?? builtin ?? NSScreen.main ?? NSScreen.screens.first
    }
  }

  /// Settings changed the display: go there now (leaving and re-entering full
  /// screen, which is how a full-screen window changes displays).
  func moveToPreferredScreen() {
    guard let window, let target = Dashboard.preferredScreen(), window.screen != target else { return }
    let wasFull = isFullScreen
    let place = {
      // land wholly inside the target's usable area first: a frame that includes the
      // menu-bar strip gets pushed back by macOS and can end up straddling two displays
      let vf = target.visibleFrame
      window.setFrame(vf.insetBy(dx: vf.width * 0.08, dy: vf.height * 0.06), display: true)
      if wasFull { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if !self.isFullScreen { window.toggleFullScreen(nil) } } }
      else { Pages.shared.send("window.onDisplays && onDisplays()") }
    }
    if wasFull { moveAfterExit = place; window.toggleFullScreen(nil) } else { place() }
  }
  private var moveAfterExit: (() -> Void)?

  /// background: opened by the login/wake helper — never steal focus or switch Space.
  func start(background: Bool) {
    guard let screen = Dashboard.preferredScreen() else {
      // no display at all (lid closed, nothing attached): try again when one appears
      NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
        guard let self, self.window == nil, !NSScreen.screens.isEmpty else { return }
        self.start(background: background)
      }
      return
    }
    let initial = mode == "window" ? screen.visibleFrame.insetBy(dx: screen.visibleFrame.width * 0.08, dy: screen.visibleFrame.height * 0.06) : screen.frame
    window = NSWindow(contentRect: initial, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                      backing: .buffered, defer: false, screen: screen)
    window.title = "Manara"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.backgroundColor = NSColor(srgbRed: 0.106, green: 0.118, blue: 0.141, alpha: 1)
    window.collectionBehavior = [.fullScreenPrimary]
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.minSize = NSSize(width: 560, height: 420)
    window.contentView = Backdrop(page: Pages.shared.make("dashboard.html"))   // the theme's backdrop sits behind the page
    window.setFrameAutosaveName("WorkDashboardWindow")     // size + position survive restarts
    // …but only on the display Settings asks for: a frame remembered on another display
    // (or across two) would win over dashboard.display, and full screen opens wherever
    // the window is. Land wholly inside the target's usable area (see moveToPreferredScreen).
    landOnPreferredScreen()
    if background {
      window.orderBack(nil)                                 // there, but behind your work
      pendingFullScreen = mode == "fullscreen"              // goes full screen when you first open it
    } else {
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      // ordering front can drop a new window on the display you're working on: put it back first
      if mode == "fullscreen" { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.landOnPreferredScreen(); self.window.toggleFullScreen(nil) } }
    }
  }

  /// Not in full screen: put the window wholly inside the preferred display's usable area,
  /// unless it already is (a remembered window frame there is kept).
  private func landOnPreferredScreen() {
    guard let window, !isFullScreen, let target = Dashboard.preferredScreen() else { return }
    let vf = target.visibleFrame
    if window.screen != target || !vf.insetBy(dx: -1, dy: -1).contains(window.frame) {
      window.setFrame(vf.insetBy(dx: vf.width * 0.08, dy: vf.height * 0.06), display: false)
    }
  }

  @objc func show() {
    guard window != nil else { return }   // no display yet: start() opens it when one appears
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    if pendingFullScreen {
      pendingFullScreen = false
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { if !self.isFullScreen { self.landOnPreferredScreen(); self.window.toggleFullScreen(nil) } }
    }
  }

  var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) ?? false }

  /// The header's Window / Full screen button.
  func toggleMode() {
    pendingFullScreen = false
    window?.toggleFullScreen(nil)
  }
  func windowDidEnterFullScreen(_ n: Notification) {
    mode = "fullscreen"; Pages.shared.send("window.onWindowMode && onWindowMode('fullscreen')")
    Pages.shared.send("window.onDisplays && onDisplays()")   // Settings → Placement shows where it landed
  }
  func windowDidChangeScreen(_ n: Notification) { Pages.shared.send("window.onDisplays && onDisplays()") }
  func windowDidExitFullScreen(_ n: Notification) {
    if let move = moveAfterExit { moveAfterExit = nil; move(); return }   // only passing through to change displays
    mode = "window"; Pages.shared.send("window.onWindowMode && onWindowMode('window')")
  }

  // Closing hides it; the app keeps running in the menu bar.
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if isFullScreen { NSApp.hide(nil) } else { window.orderOut(nil) }
    return false
  }
}

// ── quick tools ─────────────────────────────────────────────────────────────
final class PalettePanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}

final class Palette: NSObject, NSWindowDelegate {
  var panel: PalettePanel!
  var page: PageView!

  func start() {
    panel = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: 840, height: 580),
                         styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable], backing: .buffered, defer: false)
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach { panel.standardWindowButton($0)?.isHidden = true }
    panel.isMovableByWindowBackground = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.delegate = self
    page = Pages.shared.make("palette.html")
    let fx = NSVisualEffectView()
    fx.material = .hudWindow; fx.state = .active; fx.blendingMode = .behindWindow
    fx.wantsLayer = true; fx.layer?.cornerRadius = 18; fx.layer?.masksToBounds = true
    page.translatesAutoresizingMaskIntoConstraints = false
    fx.addSubview(page)
    NSLayoutConstraint.activate([page.leadingAnchor.constraint(equalTo: fx.leadingAnchor), page.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
                                 page.topAnchor.constraint(equalTo: fx.topAnchor), page.bottomAnchor.constraint(equalTo: fx.bottomAnchor)])
    panel.contentView = fx
  }

  func toggle() { panel.isVisible && panel.isKeyWindow ? hide() : show(tool: nil) }

  func show(tool: String?) {
    let mouse = NSEvent.mouseLocation
    guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
    let f = screen.visibleFrame, s = panel.frame.size
    panel.setFrameOrigin(NSPoint(x: f.midX - s.width / 2, y: f.midY - s.height / 2 + f.height * 0.08))
    panel.makeKeyAndOrderFront(nil)
    page.evaluateJavaScript("window.onPaletteShow && window.onPaletteShow(\(tool.map { jsString($0) } ?? "null"))")
  }

  /// Closing forgets the clipboard and what you typed (the page keeps nothing).
  func hide() {
    panel.orderOut(nil)
    page.evaluateJavaScript("window.onPaletteHide && window.onPaletteHide()")
  }
  func windowDidResignKey(_ n: Notification) { hide() }   // click elsewhere → gone, like Spotlight
}

// ── menu bar ────────────────────────────────────────────────────────────────
final class StatusBar: NSObject {
  weak var app: AppDelegate?
  private var item: NSStatusItem!
  private var links: [String] = []
  var isInstalled: Bool { item?.button != nil && item.isVisible }

  func start() {
    item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    update([:])
    NotificationCenter.default.addObserver(forName: .init("WDArrangeChanged"), object: nil, queue: .main) { [weak self] _ in self?.rebuildMenu() }
  }

  private var last: [String: Any] = [:]

  /// From the dashboard page: {count, level, line, items:[{kind,title,url}]}.
  func update(_ s: [String: Any]) {
    last = s
    let level = s["level"] as? String ?? "none"
    let color: NSColor = ["red": .systemRed, "amber": .systemOrange, "clear": .systemGreen][level] ?? .tertiaryLabelColor
    let title = NSMutableAttributedString(string: "●", attributes: [.foregroundColor: color, .font: NSFont.systemFont(ofSize: 10), .baselineOffset: 1])
    if let n = s["count"] as? Int, n > 0 {
      title.append(NSAttributedString(string: " \(n)", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)]))
    }
    item.button?.attributedTitle = title
    item.button?.toolTip = s["line"] as? String
    rebuildMenu()
  }

  private func rebuildMenu() {
    let m = NSMenu()
    let head = NSMenuItem(title: (last["line"] as? String) ?? "Loading…", action: nil, keyEquivalent: ""); head.isEnabled = false
    m.addItem(head)
    links = []
    if let items = last["items"] as? [[String: Any]], !items.isEmpty {
      m.addItem(.separator())
      for it in items.prefix(8) {
        let t = it["title"] as? String ?? ""
        let mi = NSMenuItem(title: "\(it["kind"] as? String ?? "")   \(t.count > 64 ? String(t.prefix(62)) + "…" : t)", action: #selector(openLink(_:)), keyEquivalent: "")
        mi.target = self; mi.tag = links.count
        links.append(it["url"] as? String ?? "")
        m.addItem(mi)
      }
    }
    m.addItem(.separator())
    add(m, "Open Dashboard", #selector(AppDelegate.openDashboard), "d", [.command, .option, .control])
    add(m, "Quick Tools", #selector(AppDelegate.openPalette), "k", [.command, .option])
    add(m, (app?.widgets.arranging ?? false) ? "Done Arranging Widgets" : "Arrange Widgets", #selector(AppDelegate.toggleArrange), "", [])
    add(m, "Refresh Now", #selector(AppDelegate.refreshNow), "", [])
    m.addItem(.separator())
    add(m, "Settings…", #selector(AppDelegate.showSettings), ",", [.command])
    m.addItem(withTitle: "Quit Manara", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    item.menu = m
  }

  private func add(_ m: NSMenu, _ title: String, _ sel: Selector, _ key: String, _ mods: NSEvent.ModifierFlags) {
    let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
    i.keyEquivalentModifierMask = mods; i.target = app
    m.addItem(i)
  }

  @objc func openLink(_ s: NSMenuItem) {
    // the same rule as the pages: web links only (an alert link can come from a calendar invite)
    guard s.tag < links.count, let u = safeURL(links[s.tag]) else { return }
    NSWorkspace.shared.open(u)
  }
}

// ── global shortcuts (Carbon: needs no Accessibility permission) ────────────
var hotKeyActions: [UInt32: () -> Void] = [:]
/// Each global shortcut's registration result (noErr = registered), for the self-test.
var hotKeyStatus: [UInt32: OSStatus] = [:]
private var hotKeyRefs: [EventHotKeyRef?] = []
func installHotKeys(_ keys: [(UInt32, Int, Int, () -> Void)]) {
  var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
  InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
    var hk = EventHotKeyID()
    GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
    DispatchQueue.main.async { hotKeyActions[hk.id]?() }
    return noErr
  }, 1, &spec, nil, nil)
  for (id, code, mods, action) in keys {
    hotKeyActions[id] = action
    var ref: EventHotKeyRef?
    let st = RegisterEventHotKey(UInt32(code), UInt32(mods), EventHotKeyID(signature: OSType(0x5744_4248), id: id), GetApplicationEventTarget(), 0, &ref)
    hotKeyStatus[id] = st
    if st != noErr { NSLog("WorkDashboard: shortcut %d is taken by another app (%d)", id, st) }
    hotKeyRefs.append(ref)
  }
}
