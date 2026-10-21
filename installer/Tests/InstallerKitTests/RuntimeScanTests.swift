import Foundation
import Testing
@testable import InstallerKit

@Suite("RuntimeScan")
struct RuntimeScanTests {

    private func pe(_ dir: URL, _ name: String, bits: Int = 64, imports: [String], dotNet: Bool = false) throws -> URL {
        let url = dir.appending(path: name)
        try TestPE.build(bits: bits, imports: imports, dotNet: dotNet).write(to: url)
        return url
    }

    @Test("Reads the import directory of 32- and 64-bit programs")
    func peImports() throws {
        let dir = try tempFolder([:])
        for bits in [32, 64] {
            let exe = try pe(dir, "game\(bits).exe", bits: bits, imports: ["KERNEL32.dll", "MSVCP140.dll", "d3dx9_43.dll"])
            let info = try #require(PEImports.scan(exe))
            #expect(info.dlls == ["kernel32", "msvcp140", "d3dx9_43"])
            #expect(!info.isDotNet)
        }
    }

    @Test("DLL names map to verbs, or to nothing when Wine or Mono already covers them", arguments: [
        ("msvcp140", "vcrun2022"), ("vcruntime140_1", "vcrun2022"), ("concrt140", "vcrun2022"),
        ("msvcr120", "vcrun2013"), ("msvcp120", "vcrun2013"), ("msvcr110", "vcrun2012"),
        ("msvcr100", "vcrun2010"), ("msvcr90", "vcrun2008"),
        ("d3dx9_43", "d3dx9"), ("d3dx10_43", "d3dx10"), ("d3dx11_42", "d3dx11_43"),
        ("d3dcompiler_43", "d3dcompiler_43"), ("openal32", "openal"), ("physxloader", "physx"),
        ("xinput1_3", nil), ("mscoree", nil), ("kernel32", nil), ("unityplayer", nil),
    ])
    func mapping(dll: String, verb: String?) {
        #expect(RuntimeScan.need(for: dll)?.verb == verb)
    }

    @Test("The program and its folder's DLLs decide the verbs")
    func scan() throws {
        let dir = try tempFolder([:])
        let exe = try pe(dir, "game.exe", imports: ["msvcp140.dll", "d3dx9_43.dll", "d3dx11_42.dll", "xinput1_3.dll"])
        try pe(dir, "sound.dll", imports: ["openal32.dll"])
        let report = RuntimeScan.scan(exe: exe)
        #expect(report.steps.map(\.verb) == ["vcrun2022", "d3dx9", "d3dx11_43", "openal"])
        #expect(report.steps.map(\.label) == ["Visual C++ 2015–2022", "DirectX 9", "DirectX 11", "OpenAL"])
        #expect(!report.isDotNet)
    }

    @Test("A DLL that ships next to the program is skipped")
    func shipped() throws {
        let dir = try tempFolder([:])
        let exe = try pe(dir, "game.exe", imports: ["msvcp140.dll", "d3dx9_43.dll"])
        try pe(dir, "msvcp140.dll", imports: [])
        #expect(RuntimeScan.scan(exe: exe).steps.map(\.verb) == ["d3dx9"])
    }

    @Test("A .NET assembly is only flagged; XNA assemblies in the folder still need the runtime")
    func dotNetAndXNA() throws {
        let dir = try tempFolder(["Microsoft.Xna.Framework.dll": "x"])
        let exe = try pe(dir, "game.exe", imports: ["mscoree.dll"])
        let report = RuntimeScan.scan(exe: exe)
        #expect(report.isDotNet)
        #expect(report.steps.map(\.verb) == ["xna40"])
        let cliOnly = try pe(try tempFolder([:]), "cli.exe", imports: [], dotNet: true)
        #expect(RuntimeScan.scan(exe: cliOnly).isDotNet)
        #expect(RuntimeScan.scan(exe: cliOnly).steps.isEmpty)
    }

    @Test("A non-PE program needs nothing")
    func notPE() throws {
        let dir = try tempFolder(["game.exe": "#!/bin/sh\nexit 0\n"])
        #expect(RuntimeScan.scan(exe: dir.appending(path: "game.exe")).steps.isEmpty)
    }
}
