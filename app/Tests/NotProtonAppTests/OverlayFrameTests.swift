import AppKit
import Testing
@testable import NotProtonApp

// The menu and the HUD cover the game's screen when it fills it, its window when it runs windowed
@MainActor
@Suite("Overlay frame")
struct OverlayFrameTests {
    // The maintainer's Mac: a 2560×1440 primary screen, the notched built-in one below it
    let external = OverlayFrame.Screen(frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                                       visible: CGRect(x: 0, y: 0, width: 2560, height: 1410))
    let builtIn = OverlayFrame.Screen(frame: CGRect(x: 542, y: -1112, width: 1710, height: 1112),
                                      visible: CGRect(x: 542, y: -1112, width: 1710, height: 1074))
    let pid: pid_t = 4242

    func window(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, layer: Int = 0, pid: pid_t? = nil, alpha: Double = 1) -> OverlayFrame.Window {
        OverlayFrame.Window(pid: pid ?? self.pid, layer: layer, bounds: CGRect(x: x, y: y, width: w, height: h), alpha: alpha)
    }

    @Test("A fullscreen game: the whole screen, as before")
    func fullscreen() throws {
        let frame = try #require(OverlayFrame.of(pid: pid, windows: [window(0, 0, 2560, 1440, layer: 26)], screens: [external, builtIn]))
        #expect(frame.rect == external.frame && !frame.windowed)
    }

    @Test("A maximized window under the menu bar counts as fullscreen")
    func maximized() throws {
        let frame = try #require(OverlayFrame.of(pid: pid, windows: [window(0, 30, 2560, 1410)], screens: [external]))
        #expect(frame.rect == external.frame)
    }

    @Test("A windowed game: its window, flipped from the top-left origin")
    func windowed() throws {
        let frame = try #require(OverlayFrame.of(pid: pid, windows: [window(880, 495, 800, 450)], screens: [external, builtIn]))
        #expect(frame.rect == CGRect(x: 880, y: 1440 - 495 - 450, width: 800, height: 450))
        #expect(frame.screen == external.frame && frame.windowed)
    }

    @Test("A window on the screen below the primary one lands on that screen")
    func secondScreen() throws {
        let frame = try #require(OverlayFrame.of(pid: pid, windows: [window(600, 1500, 800, 450)], screens: [external, builtIn]))
        #expect(frame.rect == CGRect(x: 600, y: -510, width: 800, height: 450))
        #expect(frame.screen == builtIn.frame)
    }

    @Test("A fullscreen game on the second screen covers that screen")
    func fullscreenSecondScreen() throws {
        let frame = try #require(OverlayFrame.of(pid: pid, windows: [window(542, 1440, 1710, 1112, layer: 26)], screens: [external, builtIn]))
        #expect(frame.rect == builtIn.frame)
    }

    @Test("Several windows: the game's largest visible one, never a tooltip, a hidden window or another app's")
    func severalWindows() throws {
        let windows = [
            window(10, 10, 120, 40, layer: 101),
            window(100, 100, 300, 200),
            window(0, 0, 2560, 1440, pid: 99),
            window(50, 50, 1900, 1100, alpha: 0),
            window(400, 300, 1280, 720),
        ]
        let frame = try #require(OverlayFrame.of(pid: pid, windows: windows, screens: [external]))
        #expect(frame.rect == CGRect(x: 400, y: 1440 - 300 - 720, width: 1280, height: 720))
    }

    @Test("A small window in front does not win over the fullscreen one")
    func fullscreenBehindPopup() throws {
        let frame = try #require(OverlayFrame.of(pid: pid, windows: [window(100, 100, 400, 300), window(0, 0, 2560, 1440, layer: 26)],
                                                 screens: [external]))
        #expect(frame.rect == external.frame)
    }

    @Test("A window partly off its screen is cut to that screen")
    func clipped() throws {
        let frame = try #require(OverlayFrame.of(pid: pid, windows: [window(2200, 100, 800, 450)], screens: [external]))
        #expect(frame.rect == CGRect(x: 2200, y: 1440 - 100 - 450, width: 360, height: 450))
    }

    @Test("No window of the game: nothing, the caller falls back to a screen")
    func noWindow() {
        #expect(OverlayFrame.of(pid: pid, windows: [window(0, 0, 800, 600, pid: 7)], screens: [external]) == nil)
        #expect(OverlayFrame.of(pid: pid, windows: [window(0, 0, 800, 600)], screens: []) == nil)
        #expect(OverlayFrame.of(pid: pid, windows: [window(-3000, -3000, 800, 600)], screens: [external]) == nil)
    }

    @Test("The window list's dictionaries read as windows")
    func parsesWindowList() throws {
        let info: [String: Any] = [kCGWindowOwnerPID as String: NSNumber(value: 4242), kCGWindowLayer as String: NSNumber(value: 0),
                                   kCGWindowAlpha as String: NSNumber(value: 1.0),
                                   kCGWindowBounds as String: CGRect(x: 1, y: 2, width: 3, height: 4).dictionaryRepresentation]
        #expect(OverlayFrame.Window(info) == window(1, 2, 3, 4))
        #expect(OverlayFrame.Window([:]) == nil)
    }

    // MARK: Safe area

    @Test("A window below the menu bar and the notch needs no inset; the HUD target is the window's height")
    func safeAreaWindowed() {
        let screen = builtIn.frame
        let area = OverlaySafeArea(safeTop: 38, auxiliary: [nil, nil], screen: screen, visible: builtIn.visible)
        let inside = area.within(CGRect(x: 900, y: -700, width: 800, height: 450), of: screen)
        #expect(inside.top == 0 && inside.screenHeight == 450 && inside.barTop == OS.top)
    }

    @Test("A window that reaches under the notch keeps the part it covers")
    func safeAreaUnderNotch() {
        let screen = builtIn.frame
        let area = OverlaySafeArea(safeTop: 38, auxiliary: [nil, nil], screen: screen, visible: builtIn.visible)
        let inside = area.within(CGRect(x: 900, y: screen.maxY - 30 - 600, width: 800, height: 600), of: screen)
        #expect(inside.top == 8 && inside.screenHeight == 600)
    }

    @Test("Over the whole screen the safe area is the screen's")
    func safeAreaFullscreen() {
        let screen = builtIn.frame
        let area = OverlaySafeArea(safeTop: 38, auxiliary: [nil, nil], screen: screen, visible: builtIn.visible)
        #expect(area.within(screen, of: screen) == area)
    }
}
