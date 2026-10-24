import Foundation
import Testing
@testable import InstallerKit

@Suite("Redistributables")
struct RedistributablesTests {

    @Test("Runtime installers map to winetricks verbs", arguments: [
        ("_Redist/dxwebsetup.exe", "d3dx9"),
        ("_CommonRedist/DirectX/Jun2010/DXSETUP.exe", "d3dx9"),
        ("_Redist/vcredist_x86_2010.exe", "vcrun2010"),
        ("_CommonRedist/vcredist/2013/vcredist_x64.exe", "vcrun2013"),
        ("_Redist/VC_redist.x64.exe", "vcrun2022"),
        ("_CommonRedist/vcredist/2019/VC_redist.x86.exe", "vcrun2022"),
        ("redist/dotNetFx40_Full_x86_x64.exe", "dotnet40"),
        ("redist/NDP472-KB4054530-x86-x64-AllOS-ENU.exe", "dotnet472"),
        ("redist/xnafx40_redist.msi", "xna40"),
        ("redist/PhysX_9.13.0604_SystemSoftware.msi", "physx"),
        ("redist/oalinst.exe", "openal"),
    ])
    func mapped(path: String, verb: String) {
        #expect(Redistributables.identify(path)?.verb == verb)
    }

    @Test("The game's own programs are not redistributables", arguments: [
        "game.exe", "bin/x64/witcher3.exe", "unins000.exe", "_Redist/readme.txt", "_Redist/vcredist_x86.exe",
    ])
    func notMapped(path: String) {
        #expect(Redistributables.identify(path) == nil)
    }

    @Test("Found in the install folder, each verb once, with the summary labels")
    func findInFolder() throws {
        let dir = try tempFolder([
            "game.exe": "MZ", "_Redist/dxwebsetup.exe": "MZ", "_Redist/vcredist_x64_2015.exe": "MZ",
            "_Redist/vcredist_x86_2015.exe": "MZ",
        ])
        let found = Redistributables.find(in: dir)
        #expect(found.map(\.file) == ["_Redist/dxwebsetup.exe", "_Redist/vcredist_x64_2015.exe", "_Redist/vcredist_x86_2015.exe"])
        #expect(Redistributables.verbs(found) == ["d3dx9", "vcrun2022"])
        #expect(Redistributables.labels(found) == ["DirectX 9", "Visual C++ 2015–2022"])
    }
}
