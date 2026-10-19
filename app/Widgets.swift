// Desktop widgets: each one is its own small window running web/widget.html.
//   layer      "desktop"  — on the wallpaper, under your windows (like a desk clock)
//              "floating" — always on top
//              "normal"   — an ordinary window
//   allSpaces  true: on every desktop · false: stays on the desktop it opened on
//   size       "small" 158×158 · "medium" 338×158 (default) · "large" 338×354 — the
//              macOS widget sizes, so they sit in line with the system's own widgets
// Move a widget: ⌥-drag it any time, or turn on Arrange (menu bar → Arrange widgets)
// to drag every widget. Positions are remembered per widget.
// Widgets never activate the app, so clicking one never switches desktops.

import Cocoa

final class WidgetWindow: NSPanel {
  let widgetId: String
  init(id: String, frame: NSRect) {
    widgetId = id
    super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    isReleasedWhenClosed = false
    hidesOnDeactivate = false
    isMovableByWindowBackground = false
  }
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// Shown over each widget while arranging: a dashed outline you drag.
final class ArrangeOverlay: NSView {
  let label: String
  init(label: String) { self.label = label; super.init(frame: .zero) }
  required init?(coder: NSCoder) { fatalError() }
  override func draw(_ dirty: NSRect) {
    NSColor(calibratedWhite: 0, alpha: 0.35).setFill()
    NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 22, yRadius: 22).fill()
    let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 22, yRadius: 22)
    p.lineWidth = 2; p.setLineDash([7, 5], count: 2, phase: 0)
    NSColor.white.withAlphaComponent(0.85).setStroke(); p.stroke()
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white]
    let s = NSAttributedString(string: "\(label)  ·  drag to move", attributes: attrs)
    s.draw(at: NSPoint(x: (bounds.width - s.size().width) / 2, y: (bounds.height - s.size().height) / 2))
  }
  override func mouseDown(with e: NSEvent) { window?.performDrag(with: e) }
  override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

final class Widgets: NSObject, NSWindowDelegate {
  private(set) var windows: [String: WidgetWindow] = [:]
  private var signature = ""
  private(set) var arranging = false
  private var saveWork: DispatchWorkItem?

  func start() {
    rebuild()
    Store.shared.onChange.append { [weak self] kind, _ in
      guard kind == "config", let self else { return }
      self.rebuild()
      self.restyle()   // a theme change restyles at once
    }
    DistributedNotificationCenter.default().addObserver(forName: .init("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { [weak self] _ in
      self?.restyle()   // "Match macOS" follows light / dark
    }
    NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
      self?.keepOnScreen()
      Pages.shared.send("window.onDisplays && onDisplays()")   // Settings → Placement redraws its map
    }
  }

  var specs: [[String: Any]] { Store.shared.config["widgets"] as? [[String: Any]] ?? [] }
  static let names = ["meeting": "Calendar", "alerts": "What needs you", "systems": "Systems"]
  /// The macOS widget sizes, in points.
  static let sizes: [String: NSSize] = ["small": NSSize(width: 158, height: 158), "medium": NSSize(width: 338, height: 158), "large": NSSize(width: 338, height: 354)]
  /// Always one of the fixed sizes: a missing or unknown size is medium, as Settings shows it.
  static func size(of s: [String: Any]) -> NSSize { sizes[s["size"] as? String ?? ""] ?? sizes["medium"]! }

  private func restyle() { windows.values.forEach { if let fx = $0.contentView as? NSVisualEffectView { Widgets.style(fx) } } }

  /// Widgets wear the dashboard's theme: the glass material, how light or dark it
  /// is, and a colour wash for Tinted glass. (The page swaps its text colours to match.)
  static let tintID = NSUserInterfaceItemIdentifier("widget-tint")
  static func style(_ fx: NSVisualEffectView) {
    let look = Store.shared.config["appearance"] as? [String: Any] ?? [:]
    let theme = Backdrop.theme, kind = look["glass"] as? String ?? "smoked"
    let light = theme == "light" || (theme == "glass" && kind == "frosted")
    fx.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
    fx.material = light ? .popover : .hudWindow
    fx.layer?.borderColor = (light ? NSColor(white: 0, alpha: 0.08) : NSColor(white: 1, alpha: 0.12)).cgColor
    let wash: NSColor
    switch (theme, kind) {
    case ("graphite", _): wash = NSColor(srgbRed: 0.106, green: 0.118, blue: 0.141, alpha: 0.9)
    case ("midnight", _): wash = NSColor(white: 0, alpha: 0.92)
    case ("light", _):    wash = NSColor(white: 1, alpha: 0.7)
    case (_, "clear"):    wash = NSColor(white: 0, alpha: 0.22)
    case (_, "frosted"):  wash = NSColor(white: 1, alpha: 0.42)
    case (_, "tinted"):   wash = (Backdrop.tints[look["tint"] as? String ?? "ocean"] ?? Backdrop.tints["ocean"]!).withAlphaComponent(0.34)
    default:              wash = NSColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 0.6)   // smoked
    }
    fx.subviews.first { $0.identifier == tintID }?.layer?.backgroundColor = wash.cgColor
  }

  /// Recreate widget windows when their config changes (not on every config edit).
  func rebuild() {
    let sig = specs.map { s in ["id", "type", "enabled", "layer", "allSpaces", "size"].map { "\(s[$0] ?? "")" }.joined(separator: "|") }.joined(separator: ";")
    guard sig != signature else { return }
    signature = sig
    windows.values.forEach { w in
      if let v = w.contentView?.subviews.first(where: { $0 is PageView }) as? PageView { Pages.shared.forget(v) }
      w.orderOut(nil)
    }
    windows = [:]
    var slot = 0
    for s in specs where (s["enabled"] as? Bool ?? true) {
      guard let id = s["id"] as? String, let type = s["type"] as? String else { continue }
      let w = WidgetWindow(id: id, frame: frameFor(id: id, spec: s, slot: slot)); slot += 1
      apply(spec: s, to: w)
      // the look of macOS's own desktop widgets: near-black glass that doesn't take on
      // the wallpaper's colour, a hairline edge and continuous 22 pt corners
      let fx = NSVisualEffectView()
      fx.blendingMode = .behindWindow; fx.state = .active
      fx.wantsLayer = true
      fx.layer?.cornerRadius = 22; fx.layer?.cornerCurve = .continuous; fx.layer?.masksToBounds = true
      fx.layer?.borderWidth = 0.5
      let tint = NSView(); tint.wantsLayer = true; tint.identifier = Widgets.tintID
      tint.translatesAutoresizingMaskIntoConstraints = false
      fx.addSubview(tint)
      NSLayoutConstraint.activate([tint.leadingAnchor.constraint(equalTo: fx.leadingAnchor), tint.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
                                   tint.topAnchor.constraint(equalTo: fx.topAnchor), tint.bottomAnchor.constraint(equalTo: fx.bottomAnchor)])
      let page = Pages.shared.make("widget.html", query: ["type": type, "id": id])
      page.translatesAutoresizingMaskIntoConstraints = false
      fx.addSubview(page)
      NSLayoutConstraint.activate([page.leadingAnchor.constraint(equalTo: fx.leadingAnchor), page.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
                                   page.topAnchor.constraint(equalTo: fx.topAnchor), page.bottomAnchor.constraint(equalTo: fx.bottomAnchor)])
      w.contentView = fx
      Widgets.style(fx)
      w.delegate = self
      w.orderFrontRegardless()
      windows[id] = w
    }
    // arranging needs something to arrange: with no widgets it ends, so it can't sit
    // switched on unseen and greet the next widgets in outline mode
    if arranging { setArranging(!windows.isEmpty) }
  }

  /// The window level for a widget's `layer` (also what the self-test expects).
  static func level(of s: [String: Any]) -> NSWindow.Level {
    switch s["layer"] as? String ?? "desktop" {
    case "floating": return .floating
    case "normal":   return .normal
    default:         return NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    }
  }

  private func apply(spec s: [String: Any], to w: WidgetWindow) {
    w.level = Widgets.level(of: s)
    let all = s["allSpaces"] as? Bool ?? true
    w.collectionBehavior = all ? [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
                               : [.stationary, .ignoresCycle]
  }

  private func frameFor(id: String, spec s: [String: Any], slot: Int) -> NSRect {
    if let saved = (Store.shared.state["widgetFrames"] as? [String: String])?[id] {
      var r = NSRectFromString(saved)
      let fixed = Widgets.size(of: s)
      if r.size != fixed {   // the size comes from config; keep the top-left corner where you put it
        r.origin.y += r.height - fixed.height; r.size = fixed
      }
      if r.width > 40, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(r) }) { return r }
    }
    // default: a column down the right edge of the main screen
    let size = Widgets.size(of: s), w = size.width, h = size.height
    guard let screen = NSScreen.screens.first(where: { $0.localizedName.localizedCaseInsensitiveContains("built-in") }) ?? NSScreen.main ?? NSScreen.screens.first
    else { return NSRect(x: 40, y: 40, width: w, height: h) }
    let vf = screen.visibleFrame
    let y = vf.maxY - 24 - h - CGFloat(slot) * (h + 16)
    return NSRect(x: vf.maxX - w - 24, y: max(vf.minY + 24, y), width: w, height: h)
  }

  /// Settings → Placement moved it: same as dragging it there (saved by windowDidMove).
  func move(_ id: String, to origin: NSPoint) { windows[id]?.setFrameOrigin(origin) }

  func resetFrame(_ id: String) {
    var frames = Store.shared.state["widgetFrames"] as? [String: String] ?? [:]
    frames[id] = nil
    Store.shared.setState("widgetFrames", frames)
    signature = ""; rebuild()
  }

  func setArranging(_ on: Bool) {
    let on = on && !windows.isEmpty
    arranging = on
    for (id, w) in windows {
      let spec = specs.first { $0["id"] as? String == id }
      if on {   // fixed sizes: arranging only moves them
        if !(w.contentView?.subviews.contains { $0 is ArrangeOverlay } ?? false), let cv = w.contentView {
          let o = ArrangeOverlay(label: Widgets.names[spec?["type"] as? String ?? ""] ?? id.capitalized)
          o.frame = cv.bounds; o.autoresizingMask = [.width, .height]
          cv.addSubview(o)
        }
        w.level = .floating      // above everything while you arrange
      } else {
        w.contentView?.subviews.filter { $0 is ArrangeOverlay }.forEach { $0.removeFromSuperview() }
        if let s = specs.first(where: { $0["id"] as? String == id }) { apply(spec: s, to: w) }
      }
    }
    NotificationCenter.default.post(name: .init("WDArrangeChanged"), object: nil)
  }

  /// A display went away: pull stranded widgets back, WITHOUT saving that position —
  /// the saved one is restored when the display returns.
  private var movingInCode = false
  private func keepOnScreen() {
    guard let main = NSScreen.main ?? NSScreen.screens.first else { return }   // lid closed, nothing attached
    movingInCode = true
    for w in windows.values where !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(w.frame) }) {
      let vf = main.visibleFrame
      w.setFrameOrigin(NSPoint(x: vf.maxX - w.frame.width - 24, y: vf.maxY - w.frame.height - 24))
    }
    // put widgets back where you left them if their display is back
    let frames = Store.shared.state["widgetFrames"] as? [String: String] ?? [:]
    for (id, w) in windows {
      if let f = frames[id].map(NSRectFromString), NSScreen.screens.contains(where: { $0.visibleFrame.intersects(f) }), f != w.frame { w.setFrame(f, display: true) }
    }
    DispatchQueue.main.async { self.movingInCode = false }
  }

  func windowDidMove(_ n: Notification) { if !movingInCode, let w = n.object as? WidgetWindow { scheduleSave(w) } }
  /// Save only the widget you moved: one stranded off a detached display keeps its
  /// real place for when that display comes back.
  private var moved = Set<String>()
  private func scheduleSave(_ w: WidgetWindow) {
    moved.insert(w.widgetId)
    saveWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      var frames = Store.shared.state["widgetFrames"] as? [String: String] ?? [:]
      for id in self.moved { if let w = self.windows[id] { frames[id] = NSStringFromRect(w.frame) } }
      self.moved.removeAll()
      Store.shared.setState("widgetFrames", frames)
    }
    saveWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
  }
}
