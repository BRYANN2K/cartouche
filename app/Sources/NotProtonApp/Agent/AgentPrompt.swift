import Foundation

// Agent strings shown to the user in approvals and the action log: one line, printable, bounded.
enum AgentPrompt {

    static let argCap = 200
    static let argvCap = 1_200
    static let textCap = 1_600

    static func clean(_ text: String, cap: Int = argCap) -> String {
        let scalars = text.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : Character($0)
        }
        return capped(String(scalars), cap)
    }

    // The action log keeps what was sent, control characters shown as escapes so one action stays one line.
    static func escaped(_ text: String, cap: Int = argCap) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) {
                    out += "\\u{" + String(scalar.value, radix: 16) + "}"
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return capped(out, cap)
    }

    static func capped(_ text: String, _ cap: Int) -> String {
        text.count > cap ? String(text.prefix(cap)) + "…" : text
    }

    // Every argument, each quoted when it holds a space, so what runs is what the user reads.
    static func argv(_ exe: String, _ args: [String]) -> String {
        var out = quoted(exe)
        for (index, arg) in args.enumerated() {
            let next = quoted(arg)
            if out.count + 1 + next.count > argvCap {
                return out + " … (\(args.count - index) more)"
            }
            out += " " + next
        }
        return out
    }

    private static func quoted(_ arg: String) -> String {
        let clean = clean(arg)
        return clean.isEmpty || clean.contains(" ") || clean.contains("\"")
            ? "\"" + clean.replacingOccurrences(of: "\"", with: "\\\"") + "\"" : clean
    }

    // Wine's shells, launchers, script hosts and copiers: each turns one approval into any command or any file on Z:.
    static let refusedPrograms: Set<String> = [
        "cmd", "command", "start", "winebrowser", "explorer", "rundll32", "rundll", "regsvr32",
        "wscript", "cscript", "mshta", "powershell", "pwsh", "conhost", "wineconsole", "winefile",
        "taskmgr", "control", "hh", "iexplore", "xcopy", "robocopy", "reg", "regedit", "schtasks",
        "sc", "wmic", "forfiles", "certutil", "bitsadmin", "expand", "extrac32", "msiexec", "winedbg",
        "winemenubuilder",
    ]

    static func programName(_ name: String) -> String {
        var stem = name.lowercased()
        while let last = stem.last, last == "." || last == " " { stem.removeLast() }
        for ext in [".exe", ".com"] where stem.hasSuffix(ext) {
            stem.removeLast(ext.count)
        }
        return stem
    }

    // The name as given and the file it resolves to: a renamed link to cmd.exe is still cmd.exe.
    static func refusedProgram(_ exe: URL) -> String? {
        let names = [exe.lastPathComponent, exe.resolvingSymlinksInPath().lastPathComponent]
        return names.first { refusedPrograms.contains(programName($0)) }
    }

    // cmd.exe parses a batch file's arguments, so they may carry no command syntax.
    static func refusedBatchArgument(_ exe: URL, _ args: [String]) -> String? {
        guard ["bat", "cmd"].contains((programName(exe.lastPathComponent) as NSString).pathExtension) else { return nil }
        let syntax = CharacterSet(charactersIn: "&|<>^%!\"()`").union(.controlCharacters).union(.newlines)
        return args.first { $0.unicodeScalars.contains(where: syntax.contains) }
    }

    static func checkRun(_ exe: URL, _ args: [String]) throws {
        if let refused = refusedProgram(exe) {
            throw AgentToolError("\(clean(refused)) is a shell or launcher; agents may not run it")
        }
        if refusedBatchArgument(exe, args) != nil {
            throw AgentToolError("a batch file's arguments may not hold & | < > ^ % ! \" ( ) or control characters")
        }
    }
}
