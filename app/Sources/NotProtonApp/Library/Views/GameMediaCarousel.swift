// The panel's pictures: the store page's header image first, then the store screenshots.
// Everything is cached next to the covers; offline, only what is cached shows.

import AppKit
import SwiftUI

enum MediaSlide: Hashable, Sendable {
    case header
    case screenshot(URL)
}

struct GameMediaStore: Sendable {
    var covers: CoverStore
    var namespace: String? = nil
    // The covers' own fetch, so tests and QA stub both the same way
    var fetch: HTTPFetch.Fetch { covers.fetch }
    // The store's screenshot list is kept a week; the pictures themselves for good
    static let listTTL: TimeInterval = 7 * 24 * 3600

    private func folder(_ appID: Int) -> URL { covers.cache.appending(path: "\(namespace ?? String(appID))/media", directoryHint: .isDirectory) }

    // The header image's own shape, 460 by 215, so it shows uncropped
    static let aspect: CGFloat = 460.0 / 215.0

    static func storeAPI(_ appID: Int) -> URL {
        QAEnvironment.url(URL(string: "https://store.steampowered.com/api/appdetails?appids=\(appID)&filters=basic,screenshots")!)
    }

    static func headers(_ appID: Int) -> [URL] {
        ["https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/\(appID)/header.jpg",
         "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/header.jpg"].compactMap(URL.init(string:))
    }

    // The header from the CDN, or the one the store page names, cached under one name
    func header(_ appID: Int, online: Bool) async -> URL? {
        let file = folder(appID).appending(path: "header.jpg")
        if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) { return file }
        guard online else { return nil }
        var sources = Self.headers(appID)
        if let data = try? Data(contentsOf: folder(appID).appending(path: "screenshots.json")),
           let named = Self.headerImage(data, appID: appID) { sources.append(named) }
        for source in sources {
            if let (data, status) = try? await fetch(QAEnvironment.url(source)), status == 200, CoverStore.looksLikeImage(data) {
                try? FileManager.default.createDirectory(at: folder(appID), withIntermediateDirectories: true)
                if (try? data.write(to: file, options: .atomic)) != nil { return file }
            }
        }
        return nil
    }

    static func headerImage(_ data: Data, appID: Int) -> URL? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = (root[String(appID)] as? [String: Any])?["data"] as? [String: Any] else { return nil }
        return (body["header_image"] as? String).flatMap(URL.init(string:))
    }

    func screenshots(_ appID: Int, online: Bool) async -> [URL] {
        let list = folder(appID).appending(path: "screenshots.json")
        let age = (try? FileManager.default.attributesOfItem(atPath: list.path(percentEncoded: false)))?[.modificationDate] as? Date
        var data = try? Data(contentsOf: list)
        if online, age.map({ Date().timeIntervalSince($0) > Self.listTTL }) ?? true,
           let (fresh, status) = try? await fetch(Self.storeAPI(appID)), status == 200, Self.succeeded(fresh, appID: appID) {
            data = fresh
            try? FileManager.default.createDirectory(at: folder(appID), withIntermediateDirectories: true)
            try? fresh.write(to: list, options: .atomic)
        }
        return data.map { Self.parse($0, appID: appID) } ?? []
    }

    // The store answers 200 with success false when it has nothing for now: that is not kept
    static func succeeded(_ data: Data, appID: Int) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root[String(appID)] as? [String: Any] else { return false }
        return entry["success"] as? Bool == true
    }

    static func parse(_ data: Data, appID: Int) -> [URL] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root[String(appID)] as? [String: Any],
              let body = entry["data"] as? [String: Any],
              let shots = body["screenshots"] as? [[String: Any]] else { return [] }
        return shots.compactMap { ($0["path_full"] as? String).flatMap(URL.init(string:)) }
    }

    // A screenshot or the logo copied into the cache, or the cached copy offline
    func local(_ remote: URL, appID: Int, online: Bool) async -> URL? {
        let name = remote.deletingPathExtension().lastPathComponent + "." + (remote.pathExtension.isEmpty ? "jpg" : remote.pathExtension)
        let file = folder(appID).appending(path: name)
        if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) { return file }
        guard online, let (data, status) = try? await fetch(QAEnvironment.url(remote)), status == 200,
              CoverStore.looksLikeImage(data) else { return nil }
        try? FileManager.default.createDirectory(at: folder(appID), withIntermediateDirectories: true)
        return (try? data.write(to: file, options: .atomic)) == nil ? nil : file
    }
}

struct GameMediaCarousel: View {
    let game: Game
    let appID: Int
    var online = true

    @Environment(\.covers) private var covers
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var slides: [MediaSlide] = [.header]
    @State private var current: MediaSlide? = .header
    @State private var hovering = false
    @State private var size: CGSize = .zero
    @FocusState private var focused: Bool

    private var store: GameMediaStore {
        GameMediaStore(covers: covers, namespace: game.source == .gog ? game.id.replacingOccurrences(of: ":", with: "-") : nil)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Glass.panelRadius - Glass.inset, style: .continuous)
        // The frame is set first; the pages then fill it, so the slides never size the carousel
        Color.clear
            .aspectRatio(GameMediaStore.aspect, contentMode: .fit)
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { size = $0 }
            .overlay { if size.width > 0 { pages } }
            .clipShape(shape)
        .overlay { shape.strokeBorder(Glass.edge, lineWidth: 0.5) }
        .overlay { if slides.count > 1 { controls } }
        .onHover { hovering = $0 }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { step(-1) }
        .onKeyPress(.rightArrow) { step(1) }
        .padding(Glass.inset)
        .task(id: game.id + (game.mediaScreenshots ?? []).map(\.absoluteString).joined()) {
            current = .header
            slides = [.header]
            let shots = game.source == .gog ? game.mediaScreenshots ?? [] : await store.screenshots(appID, online: online)
            guard !Task.isCancelled else { return }
            slides = [.header] + shots.map(MediaSlide.screenshot)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(game.name) pictures"))
        .accessibilityAdjustableAction { direction in
            _ = step(direction == .increment ? 1 : -1)
        }
    }

    private var pages: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(slides, id: \.self) { slide in
                    SlideView(slide: slide, game: game, appID: appID, store: store, online: online)
                        .frame(width: size.width, height: size.height)
                        .clipped()
                        .id(slide)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $current)
        .scrollIndicators(.never)
        .scrollDisabled(slides.count < 2)
    }

    private var index: Int { current.flatMap { slides.firstIndex(of: $0) } ?? 0 }

    private func step(_ by: Int) -> KeyPress.Result {
        let next = index + by
        guard slides.indices.contains(next) else { return .handled }
        withAnimation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0)) { current = slides[next] }
        return .handled
    }

    private var visibleDots: Range<Int> {
        let start = max(0, min(index - 3, slides.count - 7))
        return start..<min(slides.count, start + 7)
    }

    private var controls: some View {
        ZStack {
            HStack {
                chevron("chevron.left", label: Text("Previous Picture"), disabled: index == 0) { _ = step(-1) }
                Spacer()
                chevron("chevron.right", label: Text("Next Picture"), disabled: index == slides.count - 1) { _ = step(1) }
            }
            .padding(.horizontal, 8)
            .opacity(hovering || focused ? 1 : 0.65)
            .animation(.easeOut(duration: 0.15), value: hovering)
            VStack {
                Spacer()
                HStack(spacing: 5) {
                    ForEach(visibleDots, id: \.self) { i in
                        Circle()
                            .fill(.white.opacity(i == index ? 0.95 : 0.45))
                            .frame(width: 6, height: 6)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(.black.opacity(0.25), in: .capsule)
                .padding(.bottom, 8)
                .accessibilityHidden(true)
            }
        }
    }

    private func chevron(_ symbol: String, label: Text, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .bold))
        }
        .buttonStyle(RoundGlassStyle(size: 28))
        .environment(\.colorScheme, .dark)
        .disabled(disabled)
        .opacity(disabled ? 0 : 1)
        .accessibilityLabel(label)
    }
}

private struct SlideView: View {
    let slide: MediaSlide
    let game: Game
    let appID: Int
    let store: GameMediaStore
    let online: Bool

    @State private var image: NSImage?
    @State private var loaded = false

    var body: some View {
        Color.black.opacity(0.25)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                } else if slide == .header && loaded {
                    // No header offline: the library art stands in
                    CoverView(game: game, kind: .hero)
                } else {
                    Rectangle().fill(Glass.fill)
                }
            }
            .clipped()
            .task(id: game.mediaHeader?.absoluteString ?? String(describing: slide)) {
                let file: URL?
                switch slide {
                case .header:
                    if game.source == .gog {
                        file = if let header = game.mediaHeader { await store.local(header, appID: appID, online: online) } else { nil }
                    } else {
                        file = await store.header(appID, online: online)
                    }
                case .screenshot(let remote): file = await store.local(remote, appID: appID, online: online)
                }
                if let file { image = await Task.detached { CoverImages.image(file) }.value }
                loaded = true
            }
    }
}
