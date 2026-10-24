import Foundation
import Synchronization
import Testing

@testable import RetroArchKit

@Suite("libretro-thumbnails")
struct ThumbnailTests {

    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 1, count: 32)

    @Test func namesWithParenthesesCommasAndAmpersandsAreEscaped() throws {
        let thumbnails = Thumbnails(cache: URL(fileURLWithPath: "/tmp/unused"))
        #expect(thumbnails.url(system: "Nintendo - Super Nintendo Entertainment System", kind: .boxart,
                               name: "Super Metroid (Japan, USA) (En,Ja)").absoluteString
            == "https://thumbnails.libretro.com/Nintendo%20-%20Super%20Nintendo%20Entertainment%20System/Named_Boxarts/Super%20Metroid%20%28Japan%2C%20USA%29%20%28En%2CJa%29.png")
        #expect(thumbnails.url(system: "Nintendo - Super Nintendo Entertainment System", kind: .snap,
                               name: "Legend of Zelda, The - A Link to the Past (USA)").absoluteString
            == "https://thumbnails.libretro.com/Nintendo%20-%20Super%20Nintendo%20Entertainment%20System/Named_Snaps/Legend%20of%20Zelda%2C%20The%20-%20A%20Link%20to%20the%20Past%20%28USA%29.png")
        // The project's files carry _ where the name has & * / : ` < > ? \ | "
        #expect(Thumbnails.fileName("Mario & Luigi - Superstar Saga (USA)") == "Mario _ Luigi - Superstar Saga (USA)")
        #expect(Thumbnails.fileName("Pokemon - Red Version: 1/2 \"Test\"?") == "Pokemon - Red Version_ 1_2 _Test__")
        #expect(thumbnails.url(system: "Nintendo - Game Boy Advance", kind: .title,
                               name: "Mario & Luigi - Superstar Saga (USA)").absoluteString
            == "https://thumbnails.libretro.com/Nintendo%20-%20Game%20Boy%20Advance/Named_Titles/Mario%20_%20Luigi%20-%20Superstar%20Saga%20%28USA%29.png")
        // Accents are escaped as UTF-8
        #expect(thumbnails.url(system: "Sony - PlayStation", kind: .boxart, name: "Pokémon Stadium").absoluteString
            .hasSuffix("/Pok%C3%A9mon%20Stadium.png"))
    }

    @Test func aPictureIsCachedAndShownOfflineAfterItsFirstView() async throws {
        let work = try scratchFolder("thumbs")
        let asked = Mutex<[String]>([])
        let offline = Mutex(false)
        let png = png
        let thumbnails = Thumbnails(cache: work.appending(path: "covers")) { url in
            if offline.withLock({ $0 }) { throw URLError(.notConnectedToInternet) }
            asked.withLock { $0.append(url.lastPathComponent) }
            return (png, 200)
        }
        let system = "Nintendo - Super Nintendo Entertainment System", name = "Super Metroid (Japan, USA) (En,Ja)"
        #expect(thumbnails.local(system: system, kind: .boxart, name: name) == nil)
        let first = try #require(await thumbnails.image(system: system, kind: .boxart, name: name))
        #expect(try Data(contentsOf: first) == png)
        #expect(first.path.hasSuffix("covers/\(system)/Named_Boxarts/\(name).png"))

        offline.withLock { $0 = true }
        #expect(await thumbnails.image(system: system, kind: .boxart, name: name) == first)
        #expect(thumbnails.local(system: system, kind: .boxart, name: name) == first)
        #expect(asked.withLock { $0 }.count == 1)
        // Never seen before: nothing to show offline
        #expect(await thumbnails.image(system: system, kind: .snap, name: name) == nil)
    }

    @Test func anErrorPageIsNeverKeptAsAPicture() async throws {
        let work = try scratchFolder("thumbs-404")
        let thumbnails = Thumbnails(cache: work) { _ in (Data("<html>Not Found</html>".utf8), 404) }
        #expect(await thumbnails.image(system: "Sony - PlayStation", kind: .boxart, name: "X") == nil)
        let wrong = Thumbnails(cache: work) { _ in (Data("<html>".utf8), 200) }
        #expect(await wrong.image(system: "Sony - PlayStation", kind: .boxart, name: "X") == nil)
        let kept = FileManager.default.enumerator(atPath: work.path)?.compactMap { $0 as? String } ?? []
        #expect(!kept.contains { $0.hasSuffix(".png") })
        // A 404 is remembered, so the panel goes on to the next picture
        #expect(thumbnails.isMissing(system: "Sony - PlayStation", kind: .boxart, name: "X"))
        let offline = Thumbnails(cache: work) { _ in throw URLError(.notConnectedToInternet) }
        #expect(await offline.image(system: "Sony - PlayStation", kind: .snap, name: "X") == nil)
        #expect(!offline.isMissing(system: "Sony - PlayStation", kind: .snap, name: "X"))
    }
}
