import Foundation

// Exact binaries only: a different Wine build needs its own inspected loader hook.
enum WineSteamPatches {
    struct Entry: Sendable {
        let clean: String
        let patched: String
        let patch: NtdllPatch
        var path: String { "lib/wine/\(patch.arch.rawValue)/ntdll.dll" }
    }

    static let entries: [Entry] = [
        Entry(clean: "c62632acf163674b2459d81e6ef1475c0107d2a03671bbe98a041b4bb2de11fb", patched: "de2b6663d15d7e0e348c569413c4925442a668f29fa0bfc68e6880d34ab7c5f7",
              patch: NtdllPatch(arch: .x86_64Windows, payloadResource: "detour2-cartouche-26.3",
                                payloadSHA256: "8b89d795a528018f24116b98aab8b33c96ab1a833109ff12a015f050c9be15ce",
                                caveRVA: 0x70815, payloadRVA: 0x70820,
                                hooks: [NtdllHook(rva: 0x34d8a, stolen: [0x48, 0x8b, 0x85, 0x90, 0x00, 0x00, 0x00])],
                                caveSize: 2027, cavePad: 0xcc,
                                machine: 0x8664, magic: 0x20b, imageBase: 0x170000000,
                                placement: .padding)),
        Entry(clean: "874639b96bca14112b0a361de96a69fa1b825e9bb3fd6e2416998476faec72a5", patched: "4c7ae92760d38f9c6077b2fff1ab024b9cfef46c5cf2f16c60baeef87068757d",
              patch: NtdllPatch(arch: .i386Windows, payloadResource: "detour32-cartouche-26.3",
                                payloadSHA256: "78f0c106b8d9fe1e0b00f321c3818b56355e0dfc16ab7e58a393af020a22e6bf",
                                caveRVA: 0x231000, payloadRVA: 0x231000,
                                hooks: [NtdllHook(rva: 0x2e8a0, stolen: [0x8b, 0x45, 0x14, 0xa8, 0x01])],
                                caveSize: 4096, cavePad: 0x0,
                                machine: 0x14c, magic: 0x10b, imageBase: 0x7bc00000,
                                placement: .section))
    ]

    static func needsPreparation(_ root: URL) -> Bool {
        entries.contains { Digest.sha256IfPresent(root.appending(path: $0.path)) == $0.clean }
    }

    static func install(in root: URL) throws -> [WineArch] {
        var installed: [WineArch] = []
        for entry in entries {
            let file = root.appending(path: entry.path)
            guard Digest.sha256IfPresent(file) == entry.clean else { continue }
            let image = try NtdllPatcher.apply(entry.patch, to: Data(contentsOf: file),
                                               payload: NtdllPatcher.payload(for: entry.patch))
            guard Digest.sha256(of: image) == entry.patched else {
                throw StepFailure(step: RunnerPatcher.step, detail: "The Steam loader patch did not match its verified result.")
            }
            try RunnerPatcher.keepClean(file)
            try atomicReplace(file, with: image, step: RunnerPatcher.step)
            installed.append(entry.patch.arch)
        }
        return installed
    }
}
