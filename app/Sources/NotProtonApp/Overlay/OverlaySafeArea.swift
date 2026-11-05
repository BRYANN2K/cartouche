import AppKit

// The notch and the menu bar at the top of the game's screen: the tab bar, the status capsule and the HUD sit below them
struct OverlaySafeArea: Equatable, Sendable {
    var top: CGFloat = 0
    var screenHeight: CGFloat = 0

    init() {}

    // safeTop: the notch; auxiliary: the areas beside it; visible: the frame the menu bar leaves
    init(safeTop: CGFloat, auxiliary: [CGRect?], screen: CGRect, visible: CGRect) {
        let beside = auxiliary.compactMap { $0?.height }.max() ?? 0
        top = max(safeTop, beside, screen.maxY - visible.maxY, 0)
        screenHeight = screen.height
    }

    init(_ screen: NSScreen) {
        self.init(safeTop: screen.safeAreaInsets.top, auxiliary: [screen.auxiliaryTopLeftArea, screen.auxiliaryTopRightArea],
                  screen: screen.frame, visible: screen.visibleFrame)
    }

    // Over a window: only the part of the top band inside it, and the window's height for the in-game HUD
    func within(_ rect: CGRect, of screen: CGRect) -> OverlaySafeArea {
        var area = self
        area.top = max(0, top - (screen.maxY - rect.maxY))
        area.screenHeight = rect.height
        return area
    }

    // Where the bars and a top HUD start, from the screen's top
    var barTop: CGFloat { top > 0 ? max(OS.top, top + OS.s2) : OS.top }
}
