// In-game menu spikes S1 to S3: a glass NSPanel over a game window, cursor probes, a Carbon
// hotkey, controller Home button checks, and a native Metal stand-in game.
//   spike panel [--plan n:floating,a:screenSaver,...] [--open S] [--end S] [--game-pid PID] [--restore PID]
//               [--reactivate-game] [--cursor-probe] [--hotkey [--style activating|nonactivating] [--level L]]
//               [--policy accessory|regular]
//     levels: floating, statusBar, popUpMenu, screenSaver, shielding
//   spike native [--mode window|cover|fullscreen] [--seconds S]
//   spike pad [--seconds S]
//   spike post-key PID [shift]     posts ⌥F1 at the HID level, only while PID is frontmost (not used:
//                                  the coordinator asked for no global synthetic keys)
//   spike post-key-pid PID         posts ⌥F1 to that process only
//   spike fullscreen PID           puts PID's first window in its own Space through Accessibility
//   spike cursor-check             checks the cursor visibility probes against our own hide/unhide
//   spike activate PID | frontmost | cursor | warp X Y | space   bookkeeping around a run
//   spike capture OUT.png PID...   screenshot of those pids' windows only (needs Screen Recording)
// Every line starts with the Unix time in ms.

import AppKit
import ScreenCaptureKit
import Carbon.HIToolbox
import GameController
import Metal
import QuartzCore

setvbuf(stdout, nil, _IOLBF, 0)

func ms() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
func say(_ s: String) { print("\(ms()) \(s)") }

var args = Array(CommandLine.arguments.dropFirst())
let command = args.isEmpty ? "panel" : args.removeFirst()
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func flag(_ name: String) -> Bool { args.contains(name) }
func number(_ name: String, _ fallback: Double) -> Double { option(name).flatMap(Double.init) ?? fallback }

func builtinScreen() -> NSScreen {
    NSScreen.screens.first {
        CGDisplayIsBuiltin(($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value) != 0
    } ?? NSScreen.screens[0]
}

func frontmost() -> String {
    let app = NSWorkspace.shared.frontmostApplication
    return "\(app?.localizedName ?? "nil")/\(app?.processIdentifier ?? 0)"
}

// SkyLight's cursor state, through dlsym (the public CGCursorIsVisible always answers 0)
typealias VisibleFn = @convention(c) () -> Int32
typealias VisibleCidFn = @convention(c) (Int32) -> Int32
func sym(_ name: String) -> UnsafeMutableRawPointer? { dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) }
let mainConnection: Int32 = sym("SLSMainConnectionID").map { unsafeBitCast($0, to: VisibleFn.self)() } ?? 0
func cursorVisibility() -> String {
    var parts: [String] = []
    if let f = sym("SLCursorIsVisible") { parts.append("SLCursorIsVisible=\(unsafeBitCast(f, to: VisibleFn.self)())") }
    if let f = sym("SLSCursorIsVisible") { parts.append("SLSCursorIsVisible=\(unsafeBitCast(f, to: VisibleCidFn.self)(mainConnection))") }
    return parts.joined(separator: " ")
}
// The active Space and its type (0 desktop, 4 fullscreen), for "no Space switch"
typealias SpaceFn = @convention(c) (Int32) -> UInt64
typealias SpaceTypeFn = @convention(c) (Int32, UInt64) -> Int32
func activeSpace() -> String {
    guard let g = sym("SLSGetActiveSpace"), let t = sym("SLSSpaceGetType") else { return "space=?" }
    let id = unsafeBitCast(g, to: SpaceFn.self)(mainConnection)
    return "space=\(id) spaceType=\(unsafeBitCast(t, to: SpaceTypeFn.self)(mainConnection, id))"
}
func cursorAt() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

func level(_ name: String) -> NSWindow.Level {
    switch name {
    case "floating": return .floating
    case "statusBar": return .statusBar
    case "popUpMenu": return .popUpMenu
    case "shielding": return NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
    default: return .screenSaver
    }
}

func makePanel(activating: Bool, level: NSWindow.Level) -> NSPanel {
    let screen = builtinScreen().frame
    let size = NSSize(width: 360, height: 200)
    let frame = NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height)
    let panel = KeyPanel(contentRect: frame, styleMask: activating ? [.borderless] : [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.level = level
    panel.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces, .stationary, .ignoresCycle]
    let label = NSTextField(labelWithString: "Cartouche · spike menu")
    label.font = .systemFont(ofSize: 17, weight: .semibold)
    label.frame = NSRect(x: 24, y: 88, width: 312, height: 24)
    let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: size))
    glass.cornerRadius = 26
    let content = NSView(frame: glass.bounds)
    content.addSubview(label)
    glass.contentView = content
    panel.contentView = glass
    return panel
}

// Front-to-back on-screen windows: where the panel and the game's biggest window sit
func stack(_ panel: NSPanel?, game: pid_t) -> String {
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    var panelIndex = -1, panelLayer = 0, gameIndex = -1, gameLayer = 0, gameArea = 0.0, gameRect = CGRect.zero
    for (i, w) in list.enumerated() {
        let number = w[kCGWindowNumber as String] as? Int ?? 0
        let owner = w[kCGWindowOwnerPID as String] as? Int32 ?? 0
        let layer = w[kCGWindowLayer as String] as? Int ?? 0
        let rect = CGRect(dictionaryRepresentation: w[kCGWindowBounds as String] as! CFDictionary) ?? .zero
        if let panel, number == panel.windowNumber { panelIndex = i; panelLayer = layer }
        if owner == game, layer < 1000, rect.width * rect.height > gameArea {
            gameIndex = i; gameLayer = layer; gameArea = rect.width * rect.height; gameRect = rect
        }
    }
    let above = panelIndex >= 0 && gameIndex >= 0 && panelIndex < gameIndex
    return "panelIndex=\(panelIndex) panelLayer=\(panelLayer) gameIndex=\(gameIndex) gameLayer=\(gameLayer) gameRect=\(Int(gameRect.minX)),\(Int(gameRect.minY)),\(Int(gameRect.width))x\(Int(gameRect.height)) above=\(above)"
}

// Warps the cursor away from the game and reads it back after a few game frames: still there
// means nothing confines or re-centres it. If not, tries to force it free from our process.
func probeCursor(_ tag: String) {
    let screen = CGDisplayBounds(CGMainDisplayID())
    let target = CGPoint(x: screen.minX + 60, y: screen.minY + 80)
    func attempt() -> (Bool, CGPoint) {
        CGWarpMouseCursorPosition(target)
        usleep(200_000)
        let p = cursorAt()
        return (abs(p.x - target.x) < 2 && abs(p.y - target.y) < 2, p)
    }
    let (free, p) = attempt()
    var line = "cursor \(tag) free=\(free) at=\(Int(p.x)),\(Int(p.y)) \(cursorVisibility())"
    if !free {
        CGAssociateMouseAndMouseCursorPosition(1)
        CGDisplayShowCursor(CGMainDisplayID())
        let (forced, q) = attempt()
        line += " forced: free=\(forced) at=\(Int(q.x)),\(Int(q.y)) \(cursorVisibility())"
    }
    say(line)
}

final class PanelSpike: NSObject {
    // Steps "n:level" (non-activating) or "a:level" (activating), each open 1.8 s then closed
    let plan = (option("--plan") ?? "").split(separator: ",").map { $0.split(separator: ":").map(String.init) }
    let hotkeyActivating = option("--style") != "nonactivating"
    let game = option("--game-pid").flatMap(Int32.init) ?? 0
    let restore = option("--restore").flatMap(Int32.init)
    var panel: NSPanel?
    var gamePid: pid_t = 0
    var spaces = 0
    var hotkeys: [EventHotKeyRef?] = []

    func start() {
        say("panel start \(activeSpace()) plan=\(option("--plan") ?? "-") frontmost=\(frontmost()) cursor=\(cursorAt()) \(cursorVisibility())")
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [self] _ in
            spaces += 1
            say("space changed count=\(spaces) frontmost=\(frontmost())")
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            say("activated \(app?.localizedName ?? "?")/\(app?.processIdentifier ?? 0)")
        }
        if flag("--hotkey") { registerHotkeys() }
        var at = number("--open", 4)
        for step in plan {
            after(at) {
                self.open("plan", activating: step[0] == "a", level: level(step[1]))
                self.after(1.8) { self.close() }
            }
            at += 4.5
        }
        after(number("--end", max(at, 10))) { self.finish() }
    }

    func after(_ s: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f) }

    func open(_ why: String, activating: Bool, level: NSWindow.Level) {
        guard panel == nil else { return }
        gamePid = game
        say("open by=\(why) \(activeSpace()) activating=\(activating) level=\(level.rawValue) frontmostBefore=\(frontmost()) gamePid=\(gamePid) \(stack(nil, game: game))")
        if flag("--cursor-probe") { probeCursor("before-open") }
        let p = makePanel(activating: activating, level: level)
        panel = p
        if activating {
            NSApp.activate()
            p.makeKeyAndOrderFront(nil)
            after(0.15) {
                if !NSApp.isActive {
                    let ok = NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
                    say("activate refused, retry ignoringOtherApps ok=\(ok)")
                }
            }
        } else {
            p.orderFrontRegardless()
            p.makeKey()
        }
        for delay in [0.3, 1.2] {
            after(delay) { [self] in
                guard let p = panel else { return }
                say("shown +\(delay)s active=\(NSApp.isActive) key=\(p.isKeyWindow) onActiveSpace=\(p.isOnActiveSpace) visible=\(p.occlusionState.contains(.visible)) frontmost=\(frontmost()) \(activeSpace()) \(stack(p, game: game))")
                if delay == 1.2, flag("--cursor-probe") { probeCursor("menu-open") }
            }
        }
    }

    func close() {
        guard let p = panel else { return }
        p.orderOut(nil)
        panel = nil
        say("closed")
        if flag("--reactivate-game"), let app = NSRunningApplication(processIdentifier: gamePid), !app.isActive {
            say("reactivate game ok=\(app.activate())")
        }
        after(1.0) { say("after close frontmost=\(frontmost()) \(stack(nil, game: self.game))"); if flag("--cursor-probe") { probeCursor("menu-closed") } }
    }

    func finish() {
        if let restore, let app = NSRunningApplication(processIdentifier: restore) {
            say("restore \(app.localizedName ?? "?") ok=\(app.activate())")
        }
        say("end spaces=\(spaces) frontmost=\(frontmost())")
        exit(0)
    }

    // Carbon hotkeys: ⌥F1 (id 1) and ⌥⇧F1 (id 2); a press toggles the menu
    func registerHotkeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            say("hotkey fired id=\(id.id) frontmost=\(frontmost())")
            let spike = Unmanaged<PanelSpike>.fromOpaque(currentSpike!).takeUnretainedValue()
            if spike.panel == nil { spike.open("hotkey", activating: spike.hotkeyActivating, level: level(option("--level") ?? "screenSaver")) } else { spike.close() }
            return noErr
        }, 1, &spec, nil, nil)
        for (id, mods) in [(UInt32(1), optionKey), (UInt32(2), optionKey | shiftKey)] {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(kVK_F1), UInt32(mods), EventHotKeyID(signature: OSType(0x43415254), id: id),
                                             GetApplicationEventTarget(), 0, &ref)
            hotkeys.append(ref)
            say("hotkey register id=\(id) status=\(status)")
        }
    }
}
var currentSpike: UnsafeMutableRawPointer?

// A native stand-in game: a Metal layer cleared at vsync, rendered and shown rates once a second
final class NativeGame: NSObject {
    let mode = option("--mode") ?? "window"
    let window: NSWindow
    let layer = CAMetalLayer()
    let queue: MTLCommandQueue
    var rendered = 0, shown = 0
    let lock = NSLock()

    override init() {
        let device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        let screen = builtinScreen()
        let rect = mode == "cover" ? screen.frame : NSRect(x: screen.frame.midX - 400, y: screen.frame.midY - 250, width: 800, height: 500)
        window = NSWindow(contentRect: rect, styleMask: mode == "cover" ? [.borderless] : [.titled, .resizable, .closable],
                          backing: .buffered, defer: false, screen: screen)
        window.title = "Cartouche native stand-in"
        if mode == "cover" { window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1) }
        window.collectionBehavior = [.fullScreenPrimary]
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.displaySyncEnabled = true
        let view = NSView(frame: rect)
        view.wantsLayer = true
        view.layer = layer
        window.contentView = view
        super.init()
    }

    func start(seconds: Double) {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        say("native start mode=\(mode) frontmost=\(frontmost())")
        if mode == "fullscreen" { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.window.toggleFullScreen(nil) } }
        Thread { self.loop(seconds) }.start()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [self] _ in
            lock.lock(); let r = rendered, s = shown; rendered = 0; shown = 0; lock.unlock()
            say("tick rendered=\(r) shown=\(s) active=\(NSApp.isActive) fullscreen=\(window.styleMask.contains(.fullScreen)) level=\(window.level.rawValue)")
        }
    }

    func loop(_ seconds: Double) {
        let start = CACurrentMediaTime()
        while CACurrentMediaTime() - start < seconds {
            autoreleasepool {
                DispatchQueue.main.sync { layer.drawableSize = CGSize(width: window.frame.width * 2, height: window.frame.height * 2) }
                guard let drawable = layer.nextDrawable() else { return }
                let t = CACurrentMediaTime() - start
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = drawable.texture
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.5 + 0.5 * sin(t * 2), green: 0.3, blue: 0.5 + 0.5 * cos(t * 1.3), alpha: 1)
                let buffer = queue.makeCommandBuffer()!
                buffer.makeRenderCommandEncoder(descriptor: pass)!.endEncoding()
                drawable.addPresentedHandler { [self] d in
                    if d.presentedTime > 0 { lock.lock(); shown += 1; lock.unlock() }
                }
                buffer.present(drawable)
                buffer.commit()
                lock.lock(); rendered += 1; lock.unlock()
            }
        }
        DispatchQueue.main.async {
            if self.window.styleMask.contains(.fullScreen) { self.window.toggleFullScreen(nil) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { say("native end"); exit(0) }
        }
    }
}

// Controller: what a background app can see of the Home button
final class PadSpike: NSObject {
    func start(seconds: Double) {
        GCController.shouldMonitorBackgroundEvents = true
        say("pad start shouldMonitorBackgroundEvents=\(GCController.shouldMonitorBackgroundEvents) controllers=\(GCController.controllers().count)")
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { n in
            if let c = n.object as? GCController { self.describe(c) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            say("pad controllers after 2s=\(GCController.controllers().count)")
            let manager = GCControllerHomeButtonSettingsManager()
            do { let s = try manager.controllerHomeButtonSystemAction; say("home systemAction=\(s.action.rawValue) customized=\(s.customized.rawValue)") }
            catch { say("home systemAction error=\(error)") }
            do { let s = try manager.controllerHomeButtonInAppAction; say("home inAppAction=\(s.action.rawValue) customized=\(s.customized.rawValue)") }
            catch { say("home inAppAction error=\(error)") }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { say("pad end"); exit(0) }
    }

    func describe(_ c: GCController) {
        guard let home = c.extendedGamepad?.buttonHome ?? c.physicalInputProfile.buttons[GCInputButtonHome] else {
            say("pad \(c.vendorName ?? "?") category=\(c.productCategory) no home button")
            return
        }
        say("pad \(c.vendorName ?? "?") category=\(c.productCategory) home boundToSystemGesture=\(home.isBoundToSystemGesture) preferred=\(home.preferredSystemGestureState.rawValue)")
        home.preferredSystemGestureState = .disabled
        say("pad home preferred set to disabled, reads \(home.preferredSystemGestureState.rawValue) bound=\(home.isBoundToSystemGesture)")
        home.pressedChangedHandler = { _, _, pressed in say("pad home pressed=\(pressed) frontmost=\(frontmost()) active=\(NSApp.isActive)") }
        c.extendedGamepad?.buttonA.pressedChangedHandler = { _, _, pressed in say("pad A pressed=\(pressed) frontmost=\(frontmost())") }
    }
}

let app = NSApplication.shared
switch command {
case "native":
    let game = NativeGame()
    game.start(seconds: number("--seconds", 10))
    app.run()
case "pad":
    app.setActivationPolicy(.accessory)
    let pad = PadSpike()
    pad.start(seconds: number("--seconds", 10))
    app.run()
case "post-key":
    let pid = Int32(args.first ?? "") ?? 0
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
        say("post-key refused: frontmost is \(frontmost()), not \(pid)")
        exit(1)
    }
    let source = CGEventSource(stateID: .hidSystemState)
    let flags: CGEventFlags = args.contains("shift") ? [.maskAlternate, .maskShift] : [.maskAlternate]
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_F1), keyDown: down)!
        e.flags = flags
        e.post(tap: .cghidEventTap)
        usleep(30_000)
    }
    say("post-key sent \(args.contains("shift") ? "⌥⇧F1" : "⌥F1") to frontmost \(frontmost())")
case "post-key-pid":
    // ⌥F1 straight into one process's queue: no HID post, nothing reaches other apps
    let pid = Int32(args.first ?? "") ?? 0
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_F1), keyDown: down)!
        e.flags = .maskAlternate
        e.postToPid(pid)
        usleep(30_000)
    }
    say("post-key-pid sent ⌥F1 to pid \(pid)")
case "fullscreen":
    let pid = Int32(args.first ?? "") ?? 0
    let axApp = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
    guard let window = (value as? [AXUIElement])?.first else { say("fullscreen: no window for \(pid)"); exit(1) }
    let err = AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanTrue)
    say("fullscreen set pid=\(pid) err=\(err.rawValue) \(activeSpace())")
    usleep(1_500_000)
    var now: CFTypeRef?
    AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &now)
    say("fullscreen readback AXFullScreen=\(now as? Bool ?? false) \(activeSpace())")
case "activate":
    let app = NSRunningApplication(processIdentifier: Int32(args.first ?? "") ?? 0)
    say("activate \(app?.localizedName ?? "nil") ok=\(app?.activate() ?? false)")
case "cursor":
    let p = cursorAt()
    print("\(Int(p.x)) \(Int(p.y))")
case "warp":
    CGWarpMouseCursorPosition(CGPoint(x: Double(args[0]) ?? 0, y: Double(args[1]) ?? 0))
    CGAssociateMouseAndMouseCursorPosition(1)
case "space":
    print(activeSpace())
case "capture":
    // Our own test windows only (the given pids), on the built-in screen, half size
    let path = args[0]
    let pids = Set(args.dropFirst().compactMap { Int32($0) })
    Task {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let id = (builtinScreen().deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
            guard let display = content.displays.first(where: { $0.displayID == id }) else { exit(1) }
            let windows = content.windows.filter { pids.contains($0.owningApplication?.processID ?? -1) }
            let config = SCStreamConfiguration()
            config.width = display.width
            config.height = display.height
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, including: windows), configuration: config)
            let rep = NSBitmapImageRep(cgImage: image)
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
            say("capture \(path) windows=\(windows.count) size=\(image.width)x\(image.height)")
        } catch { say("capture error \(error)") }
        exit(0)
    }
    app.run()
case "frontmost":
    print(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
case "cursor-check":
    app.setActivationPolicy(.accessory)
    NSApp.activate()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        say("cursor-check before \(cursorVisibility()) active=\(NSApp.isActive)")
        CGDisplayHideCursor(CGMainDisplayID())
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            say("cursor-check hidden \(cursorVisibility())")
            CGDisplayShowCursor(CGMainDisplayID())
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { say("cursor-check shown \(cursorVisibility())"); exit(0) }
        }
    }
    app.run()
default:
    app.setActivationPolicy(option("--policy") == "regular" ? .regular : .accessory)
    let spike = PanelSpike()
    currentSpike = Unmanaged.passUnretained(spike).toOpaque()
    spike.start()
    app.run()
}
