// The Microsoft runtimes games carry in _Redist or _CommonRedist folders. They
// are never run: their winetricks equivalents are installed instead.

import Foundation

public struct Redistributable: Sendable, Equatable, Hashable {
    public enum Family: String, Sendable { case visualCpp, directX, dotNet, xna, physX, openAL }

    // Relative to the install folder.
    public let file: String
    public let family: Family
    public let verb: String
    // Product names, so not translated: "Visual C++ 2015–2022", "DirectX 9".
    public let label: String
}

public enum Redistributables {

    static let vcYears: [(year: String, verb: String, label: String)] = [
        ("2005", "vcrun2005", "Visual C++ 2005"), ("2008", "vcrun2008", "Visual C++ 2008"),
        ("2010", "vcrun2010", "Visual C++ 2010"), ("2012", "vcrun2012", "Visual C++ 2012"),
        ("2013", "vcrun2013", "Visual C++ 2013"), ("2015", "vcrun2022", "Visual C++ 2015–2022"),
        ("2017", "vcrun2022", "Visual C++ 2015–2022"), ("2019", "vcrun2022", "Visual C++ 2015–2022"),
        ("2022", "vcrun2022", "Visual C++ 2015–2022"),
    ]

    // Nil for anything that is not a known runtime installer.
    public static func identify(_ path: String) -> Redistributable? {
        let lower = path.lowercased().replacingOccurrences(of: "\\", with: "/")
        let name = (lower as NSString).lastPathComponent
        guard name.hasSuffix(".exe") || name.hasSuffix(".msi") else { return nil }
        func item(_ family: Redistributable.Family, _ verb: String, _ label: String) -> Redistributable {
            Redistributable(file: path, family: family, verb: verb, label: label)
        }

        if name.hasPrefix("vc_redist") || name.hasPrefix("vcredist") || lower.contains("/vcredist/") {
            // The year is in the name or in a parent folder; vc_redist without one is 2015 or later.
            if let year = vcYears.first(where: { lower.contains($0.year) }) { return item(.visualCpp, year.verb, year.label) }
            return name.hasPrefix("vc_redist") ? item(.visualCpp, "vcrun2022", "Visual C++ 2015–2022") : nil
        }
        if name == "dxwebsetup.exe" || name == "dxsetup.exe" || (lower.contains("/directx/") && name.hasPrefix("dx")) {
            return item(.directX, "d3dx9", "DirectX 9")
        }
        if let m = try? /^ndp(\d)(\d)(\d)?/.firstMatch(in: name) {
            let digits = String(m.1) + String(m.2) + (m.3.map(String.init) ?? "")
            return item(.dotNet, "dotnet" + digits, ".NET Framework " + digits.map(String.init).joined(separator: "."))
        }
        if let m = try? /^dotnetfx(\d)(\d)/.firstMatch(in: name) {
            return item(.dotNet, "dotnet\(m.1)\(m.2)", ".NET Framework \(m.1).\(m.2)")
        }
        if let m = try? /^xnafx(\d)(\d)/.firstMatch(in: name) {
            return item(.xna, "xna\(m.1)\(m.2)", "XNA Framework \(m.1).\(m.2)")
        }
        if name.contains("physx") { return item(.physX, "physx", "PhysX") }
        if name.hasPrefix("oalinst") { return item(.openAL, "openal", "OpenAL") }
        return nil
    }

    public static func find(in folder: URL) -> [Redistributable] {
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return [] }
        var base = folder.resolvingSymlinksInPath().path(percentEncoded: false)
        if base.hasSuffix("/") { base.removeLast() }
        var found: [Redistributable] = []
        for case let url as URL in walk {
            let path = url.resolvingSymlinksInPath().path(percentEncoded: false)
            let relative = path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : url.lastPathComponent
            if let item = identify(relative) { found.append(item) }
        }
        return found.sorted { $0.file < $1.file }
    }

    // Each verb once, in the order found.
    public static func verbs(_ items: [Redistributable]) -> [String] {
        var seen: Set<String> = []
        return items.map(\.verb).filter { seen.insert($0).inserted }
    }

    public static func labels(_ items: [Redistributable]) -> [String] {
        var seen: Set<String> = []
        return items.map(\.label).filter { seen.insert($0).inserted }
    }
}
