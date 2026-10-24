import Foundation
import Synchronization
import Testing

@testable import NotProtonApp

// A "mounted image" is a fixture folder shaped like Apple's evaluation image;
// the mounter is faked so nothing is really mounted. No Apple file is involved.
@Suite("Game Porting Toolkit image")
@MainActor
final class PortingToolkitDMGTests {

    struct Recorded: Sendable {
        var mounts: [URL] = []
        var unmounts: [URL] = []
    }

    let work: URL
    let runners: URL
    let dmg: URL
    final class Recorder: Sendable { let value = Mutex(Recorded()) }
    let recorded = Recorder()

    init() throws {
        work = try scratchDirectory("gptk-dmg")
        runners = work.appending(path: "runners")
        dmg = work.appending(path: "Game porting toolkit.dmg")
        try Data("not a real image".utf8).write(to: dmg)
    }

    deinit { try? FileManager.default.removeItem(at: work) }

    func mounter(at point: URL) -> DiskImageMounter {
        let recorded = recorded, dmg = dmg
        return DiskImageMounter(
            mount: { image in
                // The real mounter attaches the image read-only; the fake checks it was asked to
                guard image == dmg else {
                    throw StepFailure(step: "Mount", detail: "A different image was passed.")
                }
                recorded.value.withLock { $0.mounts.append(point) }
                return point
            },
            unmount: { point in recorded.value.withLock { $0.unmounts.append(point) } })
    }

    var unmounts: [URL] { recorded.value.withLock { $0.unmounts } }

    @Test("A dropped image imports the D3DMetal pieces and is always detached")
    func importImage() async throws {
        let point = work.appending(path: "mounted")
        let lib = try PortingToolkitTests.toolkit(at: point.appending(path: "redist/lib"))
        try Data("MZ fixture".utf8).write(to: lib.appending(path: "wine/x86_64-windows/kernel32.dll"))

        let version = try await PortingToolkitDMG.importImage(dmg, runners: runners, mounter: mounter(at: point))

        #expect(version == "4.0b3")
        #expect(recorded.value.withLock { $0.mounts } == [point])
        #expect(unmounts == [point], "the image is detached again")
        let copy = PortingToolkitSource.folder(version: "4.0b3", runners: runners)
        #expect(FileManager.default.fileExists(
            atPath: copy.appending(path: "lib/external/D3DMetal.framework").path(percentEncoded: false)))
        // Only external/ and the graphics DLLs are taken: the rest of the toolkit's own Wine stays unread
        for name in ["d3d11", "d3d12", "dxgi"] {
            #expect(FileManager.default.fileExists(
                atPath: copy.appending(path: "lib/wine/x86_64-windows/\(name).dll").path(percentEncoded: false)))
        }
        #expect(!FileManager.default.fileExists(
            atPath: copy.appending(path: "lib/wine/x86_64-windows/kernel32.dll").path(percentEncoded: false)))
        // And the runner verifies as ready
        #expect(PortingToolkitSource.verify(version: "4.0b3", runners: runners).isEmpty)
        #expect(PortingToolkitSource.copiedVersions(in: runners) == ["4.0b3"])
    }

    @Test("An image with no toolkit fails cleanly and is still detached")
    func noToolkit() async throws {
        let point = work.appending(path: "empty-image")
        try FileManager.default.createDirectory(at: point.appending(path: "Read Me"), withIntermediateDirectories: true)

        await #expect(throws: StepFailure.self) {
            try await PortingToolkitDMG.importImage(dmg, runners: runners, mounter: mounter(at: point))
        }
        #expect(unmounts == [point])
        #expect(PortingToolkitSource.copiedVersions(in: runners).isEmpty)
    }

    @Test("A failed mount reports instead of copying")
    func mountFails() async throws {
        let recorded = recorded
        let broken = DiskImageMounter(
            mount: { _ in throw StepFailure(step: "Mount", detail: "The image is damaged.") },
            unmount: { point in recorded.value.withLock { $0.unmounts.append(point) } })

        await #expect(throws: StepFailure.self) {
            try await PortingToolkitDMG.importImage(dmg, runners: runners, mounter: broken)
        }
        #expect(unmounts.isEmpty)
    }

    @Test("The onboarding import goes through the same copy and reports its version")
    func throughSetup() async throws {
        let point = work.appending(path: "mounted")
        try PortingToolkitTests.toolkit(at: point.appending(path: "redist/lib"))
        let mounter = mounter(at: point)
        let runners = runners
        let setup = SetupTasks(
            importToolkit: { image in
                try await PortingToolkitDMG.importImage(image, runners: runners, mounter: mounter)
            })

        setup.importToolkitImage(dmg)
        while setup.toolkit.working { try await Task.sleep(for: .milliseconds(10)) }

        #expect(setup.toolkit.done)
        #expect(setup.toolkitVersion == "4.0b3")
        #expect(unmounts == [point])
        #expect(PortingToolkitSource.copiedVersions(in: runners) == ["4.0b3"])
    }
}
