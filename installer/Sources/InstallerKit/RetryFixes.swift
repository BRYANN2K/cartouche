// What each retry changes in the next run's inputs, and the CLS.ini override carrying the limits to the decompressors.

import Foundation

extension InstallInputs {

    // Steps for Less Memory, in percent of RAM. Installers often ask for 75.
    static let memorySteps = [50, 35, 25]

    // Nil when the fix has nothing left to change.
    public func applying(
        _ fix: RetryFix, cores: Int = ProcessInfo.processInfo.activeProcessorCount, runners: [String] = []
    ) -> InstallInputs? {
        var next = self
        switch fix {
        case .verifyFiles:
            guard !verifyFirst else { return nil }
            next.verifyFirst = true
        case .fewerThreads:
            let now = threads ?? max(cores, 1)
            guard now > 1 else { return nil }
            next.threads = max(1, now / 2)
        case .lessMemory:
            guard let step = Self.memorySteps.first(where: { $0 < (memoryPercent ?? 75) }) else { return nil }
            next.memoryPercent = step
        case .shortPath:
            let short = #"C:\G\"# + Self.shortName(installDir)
            guard installDir != short || !shortSource else { return nil }
            next.installDir = short
            next.shortSource = true
        case .otherRunner:
            guard let index = runners.firstIndex(of: runnerID) ?? (runners.isEmpty ? nil : -1),
                  index + 1 < runners.count else { return nil }
            next.runnerID = runners[index + 1]
        }
        return next
    }

    static func shortName(_ dir: String) -> String {
        let last = dir.split(separator: "\\").last.map(String.init) ?? "Game"
        let letters = last.unicodeScalars.filter { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
        let name = String(String.UnicodeScalarView(letters.prefix(8)))
        return name.isEmpty ? "Game" : name
    }
}

//// The decompressors read their limits from a CLS.ini the installer unpacks to its temporary folder when it
//// starts; the app rewrites it there, before unpacking begins, when the run asks for less memory or fewer threads.
public enum CLSConfig {

    public static func patched(_ text: String, memoryPercent: Int?, threads: Int?) -> String {
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let lines = text.components(separatedBy: newline).map { line -> String in
            let key = line.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            guard line.contains("=") else { return line }
            if let memoryPercent, ["memory", "maxmemory", "mem", "ram"].contains(key) {
                return line.prefix { $0 != "=" } + "=\(memoryPercent)%"
            }
            if let threads, ["threads", "maxthreads", "cores", "numthreads"].contains(key) {
                return line.prefix { $0 != "=" } + "=\(threads)"
            }
            return line
        }
        return lines.joined(separator: newline)
    }

    // Temp folders of every Wine user in the prefix, a few levels down (is-XXXXX.tmp).
    public static func candidates(in prefix: URL) -> [URL] {
        let fm = FileManager.default
        let users = prefix.appending(path: "drive_c/users")
        var roots = [prefix.appending(path: "drive_c/windows/temp")]
        for user in (try? fm.contentsOfDirectory(atPath: users.path(percentEncoded: false))) ?? [] {
            roots.append(users.appending(path: "\(user)/Temp"))
            roots.append(users.appending(path: "\(user)/AppData/Local/Temp"))
        }
        var found: [URL] = []
        for root in roots {
            guard let walk = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walk {
                if walk.level > 3 { walk.skipDescendants(); continue }
                let name = url.lastPathComponent.lowercased()
                if name.hasPrefix("cls") && name.hasSuffix(".ini") { found.append(url) }
            }
        }
        return found
    }

    @discardableResult
    public static func apply(in prefix: URL, inputs: InstallInputs, done: inout Set<String>) -> [URL] {
        guard inputs.memoryPercent != nil || inputs.threads != nil else { return [] }
        var changed: [URL] = []
        for url in candidates(in: prefix) where !done.contains(url.path(percentEncoded: false)) {
            // Latin-1 maps every byte to one character, so the rest of the file is kept as is.
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .isoLatin1) else { continue }
            let new = patched(text, memoryPercent: inputs.memoryPercent, threads: inputs.threads)
            done.insert(url.path(percentEncoded: false))
            if new != text, let out = new.data(using: .isoLatin1), (try? out.write(to: url)) != nil { changed.append(url) }
        }
        return changed
    }
}
