// Manara (منارة, "lighthouse") — a calm, read-only work console for macOS.
// See README.md. This file wires the pieces together.

import Cocoa
import Carbon
import Network

final class AppDelegate: NSObject, NSApplicationDelegate {
  let dashboard = Dashboard()
  let palette = Palette()
  let widgets = Widgets()
  let statusBar = StatusBar()
  var settings: NSWindow?
  private let net = NWPathMonitor()
  private var netWasDown = false

  func applicationDidFinishLaunching(_ n: Notification) {
    Pages.shared.app = self
    statusBar.app = self
    buildMenu()
    Store.shared.start()
    Notifier.shared.start()
    Agenda.shared.start()
    statusBar.start()
    dashboard.start(background: CommandLine.arguments.contains("--background"))
    palette.start()
    widgets.start()

    SelfTest.runIfRequested(self)   // a request file from the command line: check the app unattended
    installHotKeys([
      (1, kVK_ANSI_D, cmdKey | optionKey | controlKey, { [weak self] in self?.dashboard.show() }),   // ⌃⌥⌘D
      (2, kVK_ANSI_K, cmdKey | optionKey, { [weak self] in self?.palette.toggle() }),               // ⌥⌘K
    ])

    // Refresh the moment the Mac wakes or the network comes back — not on the next tick.
    // Wi-Fi takes a few seconds to come back after the lid opens; the collectors
    // also report "offline" rather than "down" if it isn't back yet.
    NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
      Agenda.shared.refresh()
      DispatchQueue.main.asyncAfter(deadline: .now() + 6) { Store.shared.refreshAll() }
    }
    net.pathUpdateHandler = { [weak self] path in
      DispatchQueue.main.async {
        guard let self else { return }
        if path.status == .satisfied && self.netWasDown { Store.shared.refreshAll() }
        self.netWasDown = path.status != .satisfied
      }
    }
    net.start(queue: .global(qos: .utility))
  }

  // Switching to the dashboard refreshes anything older than a minute.
  func applicationDidBecomeActive(_ n: Notification) { Store.shared.refreshAll(onlyOlderThan: 60) }
  func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
  func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool { dashboard.show(); return true }

  @objc func openDashboard() { dashboard.show() }
  @objc func openPalette() { palette.show(tool: nil) }
  @objc func toggleArrange() { widgets.setArranging(!widgets.arranging) }
  @objc func refreshNow() { Store.shared.refreshAll(); Agenda.shared.refresh() }
  @objc func reloadPages() { Pages.shared.reloadAll() }

  @objc func showSettings() {
    if settings == nil {
      let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 720), styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                       backing: .buffered, defer: false)
      w.title = "Manara Settings"
      w.titlebarAppearsTransparent = true
      w.isReleasedWhenClosed = false
      w.backgroundColor = NSColor(srgbRed: 0.106, green: 0.118, blue: 0.141, alpha: 1)
      w.contentView = Pages.shared.make("settings.html")
      w.center()
      settings = w
    }
    NSApp.activate(ignoringOtherApps: true)
    settings?.makeKeyAndOrderFront(nil)
  }

  private func buildMenu() {
    let main = NSMenu()
    func sub(_ title: String, _ items: [NSMenuItem]) {
      let top = NSMenuItem(); let m = NSMenu(title: title); items.forEach { m.addItem($0) }; top.submenu = m; main.addItem(top)
    }
    func item(_ t: String, _ s: Selector?, _ k: String, _ mods: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) -> NSMenuItem {
      let i = NSMenuItem(title: t, action: s, keyEquivalent: k); i.keyEquivalentModifierMask = mods; i.target = target; return i
    }
    sub("Manara", [item("Settings…", #selector(showSettings), ",", target: self), .separator(),
                           item("Hide Manara", #selector(NSApplication.hide(_:)), "h"), .separator(),
                           item("Quit Manara", #selector(NSApplication.terminate(_:)), "q")])
    sub("Edit", [item("Undo", Selector(("undo:")), "z"), item("Redo", Selector(("redo:")), "Z"), .separator(),
                 item("Cut", #selector(NSText.cut(_:)), "x"), item("Copy", #selector(NSText.copy(_:)), "c"),
                 item("Paste", #selector(NSText.paste(_:)), "v"), item("Select All", #selector(NSText.selectAll(_:)), "a")])
    sub("View", [item("Reload", #selector(reloadPages), "r", target: self),
                 item("Refresh Data", #selector(refreshNow), "r", [.command, .shift], target: self),
                 item("Arrange Widgets", #selector(toggleArrange), "e", [.command, .option, .control], target: self), .separator(),
                 item("Toggle Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.control, .command])])
    NSApp.mainMenu = main
  }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
