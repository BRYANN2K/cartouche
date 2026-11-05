import SwiftUI

// The whole overlay over the game's screen: scrim, tab bar, window, status capsule, toasts
struct OverlayView: View {
    @Bindable var center: OverlayCenter
    var shown = true
    var close: () -> Void = {}
    // The game's own HUD is drawn by the library; this one stands in for protected games and snapshots
    var nativeHUD = false
    @Environment(\.overlayLook) private var look

    private var top: CGFloat { center.safeArea.barTop }

    var body: some View {
        GeometryReader { geo in
            let column = min(1040, max(640, min(geo.size.width * 0.62, geo.size.width - 2 * OS.slot)))
            ZStack(alignment: .top) {
                Color.black.opacity(shown ? 0.2 : 0)
                    .contentShape(Rectangle())
                    .onTapGesture { if center.clickOutside() { close() } }
                if nativeHUD {
                    HUDOverlayCorner(center: center)
                }
                if shown {
                    VStack(spacing: OS.s3) {
                        OverlayTabBar(center: center)
                            .frame(width: column, height: OS.bar)
                            .transition(barTransition)
                        OverlayWindow(center: center, close: close)
                            .frame(width: column)
                            .frame(maxHeight: min(geo.size.height * 0.8, geo.size.height - top - OS.bar - OS.s3 - OS.edge), alignment: .top)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(windowTransition)
                    }
                    .padding(.top, top)
                    StatusCapsule(center: center)
                        .frame(maxWidth: .infinity, alignment: center.settings.corner == .topRight ? .leading : .trailing)
                        .padding(.horizontal, OS.edge)
                        .padding(.top, top)
                        .transition(barTransition)
                }
                ToastStack(center: center)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, OS.edge)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .environment(\.colorScheme, .dark)
        .animation(shown ? OverlayMotion.open(look.reduceMotion) : OverlayMotion.close(look.reduceMotion), value: shown)
    }

    private var barTransition: AnyTransition {
        look.reduceMotion ? AnyTransition.opacity
            : .offset(y: -8).combined(with: .scale(scale: 0.98, anchor: .top)).combined(with: .opacity).combined(with: AnyTransition(.blurReplace))
    }

    private var windowTransition: AnyTransition {
        look.reduceMotion ? AnyTransition.opacity
            : .asymmetric(
                insertion: .offset(y: 8).combined(with: .scale(scale: 0.96, anchor: .top)).combined(with: .opacity)
                    .combined(with: AnyTransition(.blurReplace)).animation(OverlayMotion.open(false).delay(OverlayMotion.stagger)),
                removal: .opacity.combined(with: .offset(y: 4)))
    }
}

struct OverlayTabBar: View {
    @Bindable var center: OverlayCenter
    @Namespace private var space
    @Environment(\.overlayLook) private var look

    enum Mode { case full, short, icon }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            tabs(.full)
            tabs(.short)
            tabs(.icon)
        }
        .padding(OS.s1)
        .frame(height: OS.bar)
        .overlaySurface(Capsule())
    }

    private func tabs(_ mode: Mode) -> some View {
        HStack(spacing: 0) {
            ForEach(OverlaySection.allCases) { section in
                tab(section, mode)
            }
        }
        .fixedSize(horizontal: mode != .icon, vertical: false)
    }

    private func tab(_ section: OverlaySection, _ mode: Mode) -> some View {
        let on = center.nav.section == section
        let ctx = center.context
        let locked = ctx.isLocked(section), soon = ctx.isSoon(section)
        let color = locked ? look.label3 : on ? Color.white : look.label2
        return Button { center.select(section) } label: {
            HStack(spacing: 6) {
                Image(systemName: locked ? "lock" : section.symbol)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(locked || (on && soon) ? look.label3 : color)
                if mode == .full { Text(section.title) }
                else if mode == .short || on { Text(section.short) }
                if soon {
                    Circle().fill(look.label3).frame(width: 5, height: 5).padding(.leading, 2)
                        .accessibilityLabel(ot("Coming Soon"))
                }
            }
            .font(.system(size: OS.t2, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, mode == .full ? 10 : OS.s3)
            .fixedSize(horizontal: mode == .icon && on, vertical: false)
            .frame(maxWidth: mode == .icon && !on ? .infinity : nil)
            .frame(height: OS.bar - 2 * OS.s1)
            .background {
                if on {
                    Capsule().fill(.white.opacity(0.2))
                        .overlay(alignment: .top) { Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5) }
                        .shadow(color: .black.opacity(0.22), radius: 1.5, y: 1)
                        .overlay {
                            if center.nav.zone == .tabs && center.nav.input != .pointer {
                                Capsule().strokeBorder(OS.focus, lineWidth: 3).padding(-1.5)
                            } else if look.contrast {
                                Capsule().strokeBorder(.white.opacity(0.8), lineWidth: 1.5)
                            }
                        }
                        .matchedGeometryEffect(id: "tab", in: space)
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(OverlayPressStyle())
        .layoutPriority(on ? 1 : 0)
        .help(section.title)
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
        .animation(OverlayMotion.pill(look.reduceMotion), value: center.nav.section)
    }
}

struct OverlayWindow: View {
    @Bindable var center: OverlayCenter
    var close: () -> Void
    @Environment(\.overlayLook) private var look

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                OverlaySectionView(center: center)
                    .id(center.nav.section)
                    .transition(OverlayMotion.content(slide: center.nav.slide, input: center.nav.input, reduce: look.reduceMotion))
                    .padding(OS.s4)
            }
            .scrollIndicators(.never)
            .softScrollEdges(top: OS.s4, bottom: OS.s4)
            .animation(center.nav.input == .pointer ? OverlayMotion.height(look.reduceMotion) : nil, value: center.nav.section)
            footer
        }
        .overlaySurface(RoundedRectangle(cornerRadius: OS.window, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: OS.s3) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 16))
                .frame(width: 32, height: 32)
                .background(OS.fill2, in: RoundedRectangle(cornerRadius: OS.row, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: center.game.name)
                    .font(.system(size: OS.t3, weight: .semibold))
                    .tracking(-0.15)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let name = center.game.antiCheat {
                    Label { Text(verbatim: name) } icon: { Image(systemName: "lock").foregroundStyle(look.label3) }
                        .labelStyle(Tight())
                        .font(.system(size: OS.t1))
                        .foregroundStyle(look.label2)
                } else if center.profile.isModified {
                    HStack(spacing: 5) {
                        Circle().fill(OS.orange).frame(width: 6, height: 6)
                        Text(ot("Profile Modified"))
                    }
                    .font(.system(size: OS.t1))
                    .foregroundStyle(look.label2)
                }
            }
            Spacer(minLength: OS.s3)
            if center.profile.isModified {
                OverlayButton(title: ot("Save"), prominent: true) { center.save() }
                    .keyboardShortcut("s", modifiers: .command)
            }
            OverlayButton(title: center.nav.quitArmed ? ot("Confirm") : ot("Quit Game"), danger: true, armed: center.nav.quitArmed) {
                if center.quitPressed() { close() }
            }
        }
        .padding(.horizontal, OS.s4)
        .padding(.top, OS.s3)
        .padding(.bottom, OS.s2)
    }

    private var footer: some View {
        HStack(spacing: OS.s4) {
            if center.nav.showsKeyHelp {
                if let help = center.focusedRow?.help {
                    Text(verbatim: help).foregroundStyle(.white).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 4) { KeyCap(text: "↩"); KeyCap(text: "A"); Text(ot("to confirm")) }
                HStack(spacing: 4) { KeyCap(text: "esc"); KeyCap(text: "B"); Text(ot("back")) }
            }
            Spacer(minLength: 0)
            Button(action: close) {
                HStack(spacing: 4) { KeyCap(text: center.hotkey); Text(ot("to resume")) }
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: OS.t1))
        .foregroundStyle(look.label2)
        .padding(.horizontal, OS.s4)
        .padding(.top, OS.s2)
        .padding(.bottom, OS.s3)
    }
}

private struct Tight: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) { configuration.icon.font(.system(size: 9)); configuration.title }
    }
}

extension EnvironmentValues {
    // A fixed time for the clock, so snapshots draw the same every minute
    @Entry var overlayClock: Date?
}

// Session time, clock and battery, in the top corner away from the HUD
struct StatusCapsule: View {
    @Bindable var center: OverlayCenter
    @Environment(\.overlayLook) private var look
    @Environment(\.overlayClock) private var clock

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let now = clock ?? timeline.date
            let minutes = Int(now.timeIntervalSince(center.live.sessionStart) / 60)
            HStack(spacing: OS.s3) {
                HStack(spacing: 5) {
                    Image(systemName: "clock").font(.system(size: 12))
                    Text(verbatim: "\(minutes / 60):" + String(format: "%02d", minutes % 60))
                }
                .help(ot("Session length"))
                Text(now, format: .dateTime.hour().minute())
                if let battery = center.live.mac.battery {
                    HStack(spacing: 5) {
                        Image(systemName: "battery.75percent").font(.system(size: 12))
                        Text(verbatim: OverlayFormat.percent(Double(battery)))
                    }
                }
            }
            .font(OS.digits(OS.t2))
            .foregroundStyle(.white)
            .padding(.horizontal, OS.s4)
            .frame(height: OS.bar)
            .overlaySurface(Capsule(), large: false)
            .environment(\.locale, OverlayText.locale)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ToastStack: View {
    @Bindable var center: OverlayCenter
    @Environment(\.overlayLook) private var look

    var body: some View {
        VStack(spacing: OS.s2) {
            ForEach(center.toasts) { toast in
                HStack(spacing: OS.s2) {
                    Text(verbatim: toast.text)
                    if toast.undo {
                        Button(ot("Undo")) {
                            center.undo()
                            center.dismissToast(toast.id)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: OS.t2, weight: .semibold))
                        .foregroundStyle(OS.undo)
                    }
                }
                .font(.system(size: OS.t2, weight: .medium))
                .padding(.horizontal, OS.s4)
                .padding(.vertical, OS.s2)
                .overlaySurface(Capsule(), large: false)
                .transition(look.reduceMotion ? AnyTransition.opacity
                    : .asymmetric(insertion: .offset(y: 8).combined(with: .scale(scale: 0.98)).combined(with: .opacity).combined(with: AnyTransition(.blurReplace)),
                                  removal: .opacity))
            }
        }
        .animation(look.reduceMotion ? .easeInOut(duration: 0.12) : .spring(duration: 0.24, bounce: 0), value: center.toasts)
    }
}
