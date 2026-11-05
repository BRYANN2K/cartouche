import AppKit

// Where the menu and the HUD sit: the game's screen when the game fills it, its window when it runs windowed
struct OverlayFrame: Equatable, Sendable {
    struct Window: Equatable, Sendable {
        var pid: pid_t
        var layer: Int
        // The window list's coordinates: origin at the top left of the primary screen
        var bounds: CGRect
        var alpha: Double = 1
    }

    struct Screen: Equatable, Sendable {
        var frame: CGRect
        var visible: CGRect
    }

    var rect: CGRect
    var screen: CGRect

    var windowed: Bool { rect != screen }

    // screens: Cocoa frames, the primary one first, as NSScreen.screens lists them
    static func of(pid: pid_t, windows: [Window], screens: [Screen]) -> OverlayFrame? {
        guard let primary = screens.first else { return nil }
        // Wine lifts a fullscreen game above the normal layer; tooltips and menus lose on size
        let own = windows.filter {
            $0.pid == pid && $0.alpha > 0 && $0.layer >= 0 && $0.layer < NSWindow.Level.screenSaver.rawValue && $0.bounds.area > 0
        }
        guard let main = own.max(by: { $0.bounds.area < $1.bounds.area }) else { return nil }
        let rect = CGRect(x: main.bounds.minX, y: primary.frame.maxY - main.bounds.maxY, width: main.bounds.width, height: main.bounds.height)
        guard let screen = screens.max(by: { $0.frame.intersection(rect).area < $1.frame.intersection(rect).area }),
              screen.frame.intersection(rect).area > 0 else { return nil }
        if rect.insetBy(dx: -1, dy: -1).contains(screen.visible) { return OverlayFrame(rect: screen.frame, screen: screen.frame) }
        return OverlayFrame(rect: rect.intersection(screen.frame), screen: screen.frame)
    }

    @MainActor
    static func live(pid: pid_t) -> (frame: OverlayFrame, screen: NSScreen)? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let screens = NSScreen.screens
        guard let frame = of(pid: pid, windows: list.compactMap(Window.init),
                             screens: screens.map { Screen(frame: $0.frame, visible: $0.visibleFrame) }),
              let screen = screens.first(where: { $0.frame == frame.screen }) else { return nil }
        return (frame, screen)
    }
}

extension OverlayFrame.Window {
    init?(_ info: [String: Any]) {
        guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
        self.init(pid: pid, layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0, bounds: rect,
                  alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1)
    }
}

// The panel's frame and the safe area inside it
struct OverlayPlacement: Equatable {
    var rect: CGRect
    var safeArea: OverlaySafeArea

    init(rect: CGRect, safeArea: OverlaySafeArea) {
        self.rect = rect
        self.safeArea = safeArea
    }

    @MainActor
    init(_ screen: NSScreen) {
        self.init(rect: screen.frame, safeArea: OverlaySafeArea(screen))
    }

    // The game's window or screen; the main screen while the game shows no window
    @MainActor
    static func live(pid: pid_t) -> OverlayPlacement? {
        guard let found = OverlayFrame.live(pid: pid) else { return NSScreen.main.map(OverlayPlacement.init) }
        return OverlayPlacement(rect: found.frame.rect, safeArea: OverlaySafeArea(found.screen).within(found.frame.rect, of: found.screen.frame))
    }
}

extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
