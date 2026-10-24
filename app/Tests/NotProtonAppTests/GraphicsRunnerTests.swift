import Foundation
import InstallerKit
import Testing
@testable import NotProtonApp

@Suite("Renderer engine isolation")
struct GraphicsRunnerTests {
    @Test("D3DMetal replaces builtin DLLs in its own engine; the original Wine and wined3d stay intact")
    func isolatedBuiltins() throws {
        let work = try scratchDirectory("graphics-engine")
        defer { try? FileManager.default.removeItem(at: work) }
        let runners = work.appending(path: "runners")
        let root = runners.appending(path: "wine-test")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appending(path: "bin"), withIntermediateDirectories: true)
        for name in ["wine", "wineserver"] {
            let file = root.appending(path: "bin/\(name)")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let original = root.appending(path: "lib/wine/x86_64-windows/d3d11.dll")
        try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("original builtin".utf8).write(to: original)
        let source = try PortingToolkitTests.toolkit(at: work.appending(path: "gptk/lib"))
        try PortingToolkitSource.copy(PortingToolkitInstall(lib: source, version: "4.0b3", origin: work), runners: runners)
        try fm.removeItem(at: runners.appending(path: "gptk-4.0b3/lib/wine/x86_64-unix"))
        let wine = WineRunner(root: root, loader: root.appending(path: "bin/wine"),
                              server: root.appending(path: "bin/wineserver"), dllPath: root.appending(path: "lib/wine").path)
        let backends = work.appending(path: "backends")
        let prepared = try GraphicsRunner.prepare(wine, backend: .d3dmetal, backends: backends, runners: runners)
        #expect(prepared.root != wine.root)
        #expect(try Data(contentsOf: original) == Data("original builtin".utf8))
        #expect(try Data(contentsOf: prepared.root.appending(path: "lib/wine/x86_64-windows/d3d11.dll")) == Data("MZ fixture".utf8))
        #expect(fm.fileExists(atPath: prepared.root.appending(path: "lib/wine/x86_64-unix/d3d11.so").path))
        #expect(try GraphicsRunner.prepare(wine, backend: .wined3d, backends: backends, runners: runners).root == wine.root)
        let first = try fm.attributesOfItem(atPath: prepared.root.path)[.modificationDate] as? Date
        _ = try GraphicsRunner.prepare(wine, backend: .d3dmetal, backends: backends, runners: runners)
        #expect(try fm.attributesOfItem(atPath: prepared.root.path)[.modificationDate] as? Date == first)
        let copied = runners.appending(path: "gptk-4.0b3/lib/wine/x86_64-windows/d3d11.dll")
        try Data("updated toolkit DLL".utf8).write(to: copied)
        #expect(GraphicsRunner.cached(wine, backend: .d3dmetal, backends: backends, runners: runners).root == wine.root)
        let updated = try GraphicsRunner.prepare(wine, backend: .d3dmetal, backends: backends, runners: runners)
        #expect(try Data(contentsOf: updated.root.appending(path: "lib/wine/x86_64-windows/d3d11.dll")) == Data("updated toolkit DLL".utf8))
        #expect(try Data(contentsOf: original) == Data("original builtin".utf8))
    }
}
