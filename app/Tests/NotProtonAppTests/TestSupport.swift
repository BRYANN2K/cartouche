import Foundation

@testable import NotProtonApp

func scratchDirectory(_ label: String) throws -> URL {
    let url = URL.temporaryDirectory.appending(path: "np-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// A stand-in install payload rather than the shipped one, so the tests do not depend on
// make having been run. The dylib has to be a real Mach-O because it gets signed.
func installTestPayload(in work: URL) throws -> InstallPayload.Located {
    let root = work.appending(path: "payload")
    let signatureDir = root.appending(path: "signatures/macos.arm64")
    try FileManager.default.createDirectory(at: signatureDir, withIntermediateDirectories: true)

    let source = work.appending(path: "probe.c")
    try Data("int np_probe(void) { return 1; }\n".utf8).write(to: source)

    let dylib = root.appending(path: SupportPaths.dylibName)
    try Shell.check("/usr/bin/clang", [
        "-dynamiclib", "-o", dylib.path(percentEncoded: false), source.path(percentEncoded: false),
    ])

    let shim = root.appending(path: "overlay-shim.dylib")
    try FileManager.default.copyItem(at: dylib, to: shim)

    let iconmaker = root.appending(path: "iconmaker")
    try FileManager.default.copyItem(at: dylib, to: iconmaker)

    let appinfo = root.appending(path: "appinfo")
    try FileManager.default.copyItem(at: dylib, to: appinfo)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: root.appending(path: "run"))
    try Data("100\n".utf8).write(to: root.appending(path: "build-time"))

    try Data("{}".utf8).write(to: signatureDir.appending(path: "1788400362.json"))
    try Data("{}".utf8).write(to: signatureDir.appending(path: "1788652215.json"))
    let altFonts = root.appending(path: "fonts/alt")
    try FileManager.default.createDirectory(at: altFonts, withIntermediateDirectories: true)
    try Data("arial".utf8).write(to: root.appending(path: "fonts/arial.ttf"))
    try Data("alt arial".utf8).write(to: altFonts.appending(path: "arial.ttf"))

    return try InstallPayload.locate(root: root)
}

func isolatedValveDownloads(in work: URL) throws -> URL {
    let downloads = work.appending(path: "downloads")
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    if let bundle = try ValvePackageManifest.bundled().bundle {
        let cached = SupportPaths.packageDownloads.appending(path: bundle.file)
        let destination = downloads.appending(path: bundle.file)
        if FileManager.default.fileExists(atPath: cached.path),
           !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.copyItem(at: cached, to: destination)
        }
    }
    return downloads
}
