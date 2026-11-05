// What app hiding does to window visibility. Invisible 1×1 windows, no activation: run with
// swiftc -o /tmp/hide-probe hide-probe.swift && /tmp/hide-probe
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

func window(canHide: Bool = true) -> NSWindow {
    let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered, defer: false)
    w.alphaValue = 0; w.ignoresMouseEvents = true; w.isReleasedWhenClosed = false; w.canHide = canHide
    return w
}

func onScreen(_ w: NSWindow) -> Bool {
    let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(w.windowNumber)) as? [[String: Any]] ?? []
    return info.first?[kCGWindowIsOnscreen as String] as? Bool ?? false
}

func after(_ then: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: then) }

DispatchQueue.main.async {
    let library = window(), closed = window(), outWhileHidden = window(), hud = window(canHide: false), lateHUD = window(canHide: false)
    library.orderFrontRegardless(); outWhileHidden.orderFrontRegardless(); hud.orderFrontRegardless()
    after {
        print("shown:  library.isVisible \(library.isVisible), closed.isVisible \(closed.isVisible)")
        app.hide(nil)
        after {
            print("hidden: isHidden \(app.isHidden), library.isVisible \(library.isVisible), closed.isVisible \(closed.isVisible), hud(canHide false) on screen \(onScreen(hud))")
            outWhileHidden.orderOut(nil)
            lateHUD.orderFrontRegardless()
            after {
                print("hidden, canHide false panel shown: isHidden \(app.isHidden), on screen \(onScreen(lateHUD))")
                app.unhideWithoutActivation()
                after {
                    print("unhidden: library.isVisible \(library.isVisible), ordered out while hidden \(outWhileHidden.isVisible), closed \(closed.isVisible)")
                    app.hide(nil)
                    after {
                        library.orderBack(nil)
                        after {
                            print("hidden, then orderBack: isHidden \(app.isHidden)")
                            exit(0)
                        }
                    }
                }
            }
        }
    }
}
app.run()
