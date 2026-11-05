import AppKit
import SwiftUI

// The What's New sheet, as docs/research/whats-new/mockup.html (v2): one capture and one line per page,
// Apple's page control, « Continuer » then « Commencer », no visible title
struct WhatsNewView: View {
    static let width: CGFloat = 640
    static let pageHeight: CGFloat = 8 + (width - 16) * 10 / 16 + 20 + 24 + 4 + 18

    let release: WhatsNewRelease
    let close: () -> Void

    @State private var scrolled: Int?
    @State private var index: Int
    @State private var position: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(release: WhatsNewRelease, start: Int = 0, close: @escaping () -> Void) {
        self.release = release
        self.close = close
        let start = min(max(start, 0), max(release.pages.count - 1, 0))
        _scrolled = State(initialValue: start)
        _index = State(initialValue: start)
        _position = State(initialValue: CGFloat(start))
    }

    private var pages: [WhatsNewPage] { release.pages }
    private var onLast: Bool { index == pages.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            pager.frame(height: Self.pageHeight)
            footer
        }
        .frame(width: Self.width)
        .background { keys }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(WhatsNewText.string("whatsnew.header", release.version))
    }

    @ViewBuilder private var pager: some View {
        if reduceMotion {
            ZStack {
                WhatsNewPageView(page: pages[index], number: index + 1, count: pages.count)
                    .id(index)
                    .transition(.opacity)
            }
            .animation(.easeOut(duration: 0.15), value: index)
        } else {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(pages.indices, id: \.self) { i in
                        WhatsNewPageView(page: pages[i], number: i + 1, count: pages.count, parallax: true)
                            .containerRelativeFrame(.horizontal)
                            .id(i)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.never)
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $scrolled)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.containerSize.width > 0 ? geometry.contentOffset.x / geometry.containerSize.width : 0
            } action: { _, new in
                position = new
            }
            .onChange(of: scrolled) { _, new in
                guard let new, new != index else { return }
                index = new
                announce()
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Button(WhatsNewText.string("whatsnew.skip"), action: close)
                .buttonStyle(QuietButtonStyle())
                .opacity(onLast ? 0 : 1)
                .disabled(onLast)
                .accessibilityHidden(onLast)
                .frame(maxWidth: .infinity, alignment: .leading)
            dots
            Button {
                onLast ? close() : go(index + 1)
            } label: {
                ZStack {
                    Text(WhatsNewText.string("whatsnew.continue")).opacity(onLast ? 0 : 1)
                    Text(WhatsNewText.string("whatsnew.start")).opacity(onLast ? 1 : 0)
                }
                .animation(.easeOut(duration: 0.15), value: onLast)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(PrimaryCapsuleStyle())
            .accessibilityLabel(WhatsNewText.string(onLast ? "whatsnew.start" : "whatsnew.continue"))
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(EdgeInsets(top: 24, leading: 16, bottom: 16, trailing: 16))
    }

    // Apple's page control: no track, 7 pt dots; the current one stretches to a 20 pt capsule as the pages move
    private var dots: some View {
        let at = reduceMotion ? CGFloat(index) : position
        return HStack(spacing: 0) {
            ForEach(pages.indices, id: \.self) { i in
                let near = max(0, 1 - abs(CGFloat(i) - at))
                Button { go(i) } label: {
                    Capsule()
                        .fill(Color.primary)
                        .frame(width: 7 + 13 * near, height: 7)
                        .opacity(0.3 + 0.7 * near)
                        .padding(.horizontal, 4)
                        .frame(height: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(WhatsNewText.string("whatsnew.goto", i + 1, pages.count))
                .accessibilityAddTraits(i == index ? .isSelected : [])
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : nil, value: index)
    }

    // Arrows and Escape; Return is the primary button's
    private var keys: some View {
        ZStack {
            Button("") { go(index - 1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { go(index + 1) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("", action: close).keyboardShortcut(.cancelAction)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func go(_ target: Int) {
        let target = min(max(target, 0), pages.count - 1)
        guard target != index else { return }
        if reduceMotion {
            index = target
            scrolled = target
            announce()
        } else {
            withAnimation(.spring(duration: 0.28, bounce: 0)) { scrolled = target }
        }
    }

    private func announce() {
        let text = WhatsNewText.string("whatsnew.page", index + 1, pages.count) + ". " + WhatsNewText.string(pages[index].title)
        AccessibilityNotification.Announcement(text).post()
    }
}

struct WhatsNewPageView: View {
    let page: WhatsNewPage
    let number: Int
    let count: Int
    var parallax = false

    private static let hairline = Color(light: .init(white: 0, alpha: 0.1), dark: .init(white: 1, alpha: 0.14))
    private static let backdrop = Color(red: 0x15 / 255, green: 0x15 / 255, blue: 0x1a / 255)

    var body: some View {
        VStack(spacing: 4) {
            shot.padding(.bottom, 16)
            title
            line
        }
        .padding(EdgeInsets(top: 8, leading: 8, bottom: 0, trailing: 8))
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(WhatsNewText.string("whatsnew.page", number, count))
    }

    private var shot: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return Self.backdrop
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay {
                if let image = WhatsNewImages.image(page.image) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(parallax ? 1.04 : 1)
                        .visualEffect { content, proxy in
                            content.offset(x: parallax ? -proxy.frame(in: .scrollView(axis: .horizontal)).minX * 0.02 : 0)
                        }
                }
            }
            .clipShape(shape)
            .overlay { shape.strokeBorder(Self.hairline, lineWidth: 0.5) }
            .accessibilityElement()
            .accessibilityLabel(WhatsNewText.string(page.alt))
            .accessibilityAddTraits(.isImage)
    }

    private var title: some View {
        HStack(spacing: 8) {
            Text(WhatsNewText.string(page.title))
                .font(.system(size: 20, weight: .semibold))
                .tracking(-0.24)
                .accessibilityAddTraits(.isHeader)
            if page.isSoon {
                Text(WhatsNewText.string("whatsnew.soon"))
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.11)
                    .foregroundStyle(Glass.label2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Glass.fill2, in: .capsule)
            }
        }
        .frame(minHeight: 24)
        .padding(.horizontal, 24)
    }

    private var line: some View {
        let format = WhatsNewText.string(page.line)
        let text: Text
        if let shortcut = page.shortcut, let range = format.range(of: "%@") {
            text = Text(format[..<range.lowerBound])
                + Text(shortcut).fontWeight(.medium).foregroundStyle(Color.primary)
                + Text(format[range.upperBound...])
        } else {
            text = Text(format)
        }
        return text
            .font(.system(size: 13))
            .foregroundStyle(Glass.label2)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(minHeight: 18)
            .padding(.horizontal, 24)
    }
}

// Pages share the bundled JPEGs; each is read once per language
@MainActor
enum WhatsNewImages {
    private static var cache: [String: NSImage] = [:]

    static func image(_ name: String) -> NSImage? {
        let key = "\(name).\(WhatsNewText.language)"
        if let hit = cache[key] { return hit }
        guard let url = WhatsNewCatalog.imageURL(name, language: WhatsNewText.language),
              let image = NSImage(contentsOf: url) else { return nil }
        cache[key] = image
        return image
    }
}

// The one filled button, as the mockup: accent, weight 500, 104 pt wide at least
private struct PrimaryCapsuleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .frame(minWidth: 104, minHeight: 32)
            .background(Glass.accentFill, in: .capsule)
            .contentShape(.capsule)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// « Passer »: plain text, a fill only under the pointer
private struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuietBody(label: configuration.label, pressed: configuration.isPressed)
    }
}

private struct QuietBody<Label: View>: View {
    let label: Label
    let pressed: Bool
    @State private var hovered = false

    var body: some View {
        label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Glass.label2)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(hovered ? Glass.fill : .clear, in: .capsule)
            .contentShape(.capsule)
            .scaleEffect(pressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: pressed)
            .trackHover { hovered = $0 }
    }
}
