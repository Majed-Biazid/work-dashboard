// The dashboard's backdrop, which is what makes the themes possible:
//   graphite / midnight / light — a plain colour behind the page
//   glass — your desktop picture, blurred under a glass material, behind a
//           transparent page (Liquid Glass). The app draws the picture itself, so it
//           works in a full-screen Space too, where there is no desktop behind.
//           appearance.glass picks the kind: smoked (dark), clear (thin, more of the
//           picture), frosted (light, milky) or tinted (smoked + appearance.tint).
// The theme is config `appearance.theme`; "system" follows macOS light / dark.

import Cocoa

final class Backdrop: NSView {
  private let picture = NSView()
  private let glass = NSVisualEffectView()
  private let tint = NSView()
  static let tints: [String: NSColor] = ["ocean": NSColor(srgbRed: 0.10, green: 0.38, blue: 0.85, alpha: 1),
                                         "aurora": NSColor(srgbRed: 0.05, green: 0.62, blue: 0.55, alpha: 1),
                                         "dusk": NSColor(srgbRed: 0.45, green: 0.25, blue: 0.80, alpha: 1),
                                         "ember": NSColor(srgbRed: 0.90, green: 0.40, blue: 0.10, alpha: 1),
                                         "rose": NSColor(srgbRed: 0.88, green: 0.25, blue: 0.48, alpha: 1)]
  private var shownImage: URL?

  init(page: NSView) {
    super.init(frame: .zero)
    wantsLayer = true
    for v in [picture, glass, tint, page] {
      v.translatesAutoresizingMaskIntoConstraints = false
      addSubview(v)
      NSLayoutConstraint.activate([v.leadingAnchor.constraint(equalTo: leadingAnchor), v.trailingAnchor.constraint(equalTo: trailingAnchor),
                                   v.topAnchor.constraint(equalTo: topAnchor), v.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    picture.wantsLayer = true
    picture.layer?.contentsGravity = .resizeAspectFill
    glass.blendingMode = .withinWindow          // blur the picture under it, inside this window
    glass.material = .fullScreenUI
    glass.state = .active
    glass.appearance = NSAppearance(named: .darkAqua)
    tint.wantsLayer = true

    Store.shared.onChange.append { [weak self] kind, _ in if kind == "config" { self?.apply() } }
    // a desktop picture can differ per Space and per display, and can change any time
    NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.apply() }
    NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.apply() }
    DistributedNotificationCenter.default().addObserver(forName: .init("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { [weak self] _ in self?.apply() }
    Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.apply() }.tolerance = 30
  }
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }

  /// The theme as configured, with "system" resolved to light or graphite.
  static var theme: String {
    let t = (Store.shared.config["appearance"] as? [String: Any])?["theme"] as? String ?? "graphite"
    guard t == "system" else { return t }
    return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua ? "light" : "graphite"
  }

  /// The window colour and chrome (light or dark) a theme asks for — also what the self-test expects.
  static func windowLook(theme t: String, glass kind: String) -> (background: NSColor, chrome: NSAppearance.Name) {
    let bg: [String: NSColor] = ["graphite": NSColor(srgbRed: 0.106, green: 0.118, blue: 0.141, alpha: 1),
                                 "midnight": .black,
                                 "light": NSColor(srgbRed: 0.961, green: 0.961, blue: 0.969, alpha: 1)]
    let isGlass = t == "glass"
    let lightChrome = t == "light" || (isGlass && kind == "frosted")
    return (isGlass ? NSColor.black : (bg[t] ?? bg["graphite"]!), lightChrome ? .aqua : .darkAqua)
  }

  func apply() {
    let t = Backdrop.theme
    let isGlass = t == "glass"
    let look = Store.shared.config["appearance"] as? [String: Any] ?? [:]
    let kind = look["glass"] as? String ?? "smoked"
    picture.isHidden = !isGlass; glass.isHidden = !isGlass
    tint.isHidden = !(isGlass && kind == "tinted")
    if isGlass {
      let glassLook: NSAppearance.Name = kind == "frosted" ? .aqua : .darkAqua
      if glass.appearance?.name != glassLook { glass.appearance = NSAppearance(named: glassLook) }
      glass.material = kind == "frosted" ? .popover : .fullScreenUI
      glass.alphaValue = kind == "clear" ? 0.55 : 1          // thinner glass: more of the picture comes through
      tint.layer?.backgroundColor = (Backdrop.tints[look["tint"] as? String ?? "ocean"] ?? Backdrop.tints["ocean"]!).withAlphaComponent(0.30).cgColor
    }
    // the 300 s check and every config save land here: set only what changed, since a
    // new appearance redraws every view in the window, the web page included
    let (color, chrome) = Backdrop.windowLook(theme: t, glass: kind)
    if window?.backgroundColor != color { window?.backgroundColor = color }
    if window?.appearance?.name != chrome { window?.appearance = NSAppearance(named: chrome) }   // traffic lights and scrollers match
    guard isGlass else { return }
    let screen = window?.screen ?? NSScreen.main
    let url = screen.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
    guard url != shownImage else { return }
    shownImage = url
    picture.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }   // an earlier fallback gradient
    if let url, let img = NSImage(contentsOf: url) {
      picture.layer?.contents = img
      picture.layer?.backgroundColor = nil
    } else {
      // a dynamic or aerial desktop that isn't a plain image: a deep gradient instead
      let g = CAGradientLayer()
      g.colors = [NSColor(srgbRed: 0.12, green: 0.16, blue: 0.30, alpha: 1).cgColor, NSColor(srgbRed: 0.30, green: 0.14, blue: 0.24, alpha: 1).cgColor]
      g.startPoint = CGPoint(x: 0, y: 0); g.endPoint = CGPoint(x: 1, y: 1)
      picture.layer?.contents = nil
      g.frame = picture.bounds; g.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
      picture.layer?.addSublayer(g)
    }
  }
}
