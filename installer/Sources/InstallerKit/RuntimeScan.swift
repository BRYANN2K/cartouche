// What the game's own programs link against: the runtimes Wine has to provide. Bundled redist
// installers are ignored — a DLL that ships next to the program needs nothing installed, and
// Wine's own DLLs (xinput1_3, mscoree) or Wine Mono (.NET) already cover the rest.

import Foundation

public struct RuntimeStep: Sendable, Equatable, Identifiable {
    public enum Status: String, Sendable, Equatable { case waiting, installing, installed, skipped, failed }
    public let verb: String
    public let label: String
    public var status: Status = .waiting
    public var id: String { verb }
    public init(verb: String, label: String, status: Status = .waiting) {
        self.verb = verb
        self.label = label
        self.status = status
    }
}

public enum RuntimeScan {

    public struct Report: Sendable, Equatable {
        public var steps: [RuntimeStep] = []
        // A .NET assembly: reported only, Wine Mono covers .NET 4.x.
        public var isDotNet = false
    }

    static func resolvedExecutable(_ exe: URL) -> URL {
        let root = exe.deletingLastPathComponent()
        for descriptor in EngineMetadata.children(root) where descriptor.pathExtension.lowercased() == "uproject" {
            let project = descriptor.deletingPathExtension().lastPathComponent
            let shipping = root.appending(path: "\(project)/Binaries/Win64/\(project)-Win64-Shipping.exe")
            if (try? shipping.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                return shipping
            }
        }
        return exe
    }

    // The main program (past an Unreal bootstrap) plus the DLLs one level next to it.
    public static func scan(exe: URL) -> Report {
        let exe = resolvedExecutable(exe)
        let dir = exe.deletingLastPathComponent()
        var shipped: Set<String> = []
        var dlls: [URL] = []
        for item in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where item.pathExtension.lowercased() == "dll" {
            shipped.insert(item.lastPathComponent.lowercased())
            dlls.append(item)
        }
        var report = Report()
        var imported: [String] = []
        for file in [exe] + dlls.sorted(by: { $0.path(percentEncoded: false) < $1.path(percentEncoded: false) }) {
            guard let info = PEImports.scan(file) else { continue }
            report.isDotNet = report.isDotNet || info.isDotNet
            imported += info.dlls
        }
        var seen: Set<String> = []
        for dll in imported where !shipped.contains(dll + ".dll") {
            guard let need = need(for: dll), seen.insert(need.verb).inserted else { continue }
            report.steps.append(RuntimeStep(verb: need.verb, label: need.label))
        }
        if shipped.contains(where: { $0.hasPrefix("microsoft.xna.framework") }), seen.insert("xna40").inserted {
            report.steps.append(RuntimeStep(verb: "xna40", label: "XNA Framework 4.0"))
        }
        report.steps.sort { (order.firstIndex(of: $0.verb) ?? order.count) < (order.firstIndex(of: $1.verb) ?? order.count) }
        return report
    }

    static let order = ["vcrun2005", "vcrun2008", "vcrun2010", "vcrun2012", "vcrun2013", "vcrun2022",
                        "d3dx9", "d3dx10", "d3dx11_43", "d3dcompiler_43", "openal", "physx", "xna40"]

    // The winetricks verb a DLL name implies; nil when Wine's builtin DLL or Mono already covers it.
    static func need(for dll: String) -> (verb: String, label: String)? {
        switch dll {
        case "msvcp140", "msvcp140_1", "msvcp140_2", "vcruntime140", "vcruntime140_1", "concrt140":
            return ("vcrun2022", "Visual C++ 2015–2022")
        case "msvcr120", "msvcp120": return ("vcrun2013", "Visual C++ 2013")
        case "msvcr110", "msvcp110": return ("vcrun2012", "Visual C++ 2012")
        case "msvcr100", "msvcp100": return ("vcrun2010", "Visual C++ 2010")
        case "msvcr90", "msvcp90": return ("vcrun2008", "Visual C++ 2008")
        case "msvcr80", "msvcp80": return ("vcrun2005", "Visual C++ 2005")
        case "d3dcompiler_43": return ("d3dcompiler_43", "D3DCompiler 43")
        case "openal32": return ("openal", "OpenAL")
        case "physxloader", "physxloader64": return ("physx", "PhysX")
        default:
            if dll.hasPrefix("d3dx9_") { return ("d3dx9", "DirectX 9") }
            if dll.hasPrefix("d3dx10_") { return ("d3dx10", "DirectX 10") }
            if dll.hasPrefix("d3dx11_") { return ("d3dx11_43", "DirectX 11") }
            return nil
        }
    }
}
