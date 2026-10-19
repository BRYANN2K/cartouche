import Foundation
import InstallerKit
import Testing

@testable import NotProtonApp

@Suite("Installer game match")
struct InstallerMatchTests {

    @Test("The compatibility data's records are the name index")
    func compatIndex() throws {
        let index = GameIndex(compat: try CompatFixture.data())
        #expect(index.count == 4)
        let id = GameIdentification.identify(folderName: "Disco Elysium (Offline Installer) v1.0.4", index: index)
        #expect(id.match?.appID == 632_470)
        #expect(GameCover.steam(appID: 632_470)?.absoluteString.hasSuffix("/apps/632470/library_600x900.jpg") == true)
    }

    @Test("Without compatibility data nothing matches and the folder name is kept")
    func noData() {
        let id = GameIdentification.identify(folderName: "Elden Ring", index: GameIndex(compat: nil))
        #expect(id.match == nil)
        #expect(id.name == "Elden Ring")
    }
}
