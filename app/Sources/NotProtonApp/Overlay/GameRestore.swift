import Foundation

// A fullscreen Direct3D game minimizes itself when the menu takes the focus, and coming back to it
// does not restore it: game-restore.exe does, inside the game's own Wine
enum GameRestore {
    static let helperName = "game-restore.exe"

    struct Command: Equatable {
        var executable: String
        var arguments: [String]
        var environment: [String: String]
    }

    static func command(for info: GameProcesses.Info, helper: URL) -> Command? {
        guard let loader = info.environment["WINELOADER"], info.environment["WINEPREFIX"] != nil,
              let exe = info.arguments.first(where: { $0.lowercased().hasSuffix(".exe") }),
              let name = exe.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last else { return nil }
        var environment = info.environment.filter { $0.key.hasPrefix("WINE") }
        environment["WINEDEBUG"] = "-all"
        environment["PATH"] = info.environment["PATH"] ?? "/usr/bin:/bin"
        return Command(executable: "/usr/bin/arch",
                       arguments: ["-x86_64", loader, helper.path(percentEncoded: false), String(name)],
                       environment: environment)
    }

    static func run(pid: pid_t) {
        guard let root = try? InstallPayload.root() else { return }
        let helper = root.appending(path: helperName)
        guard FileManager.default.fileExists(atPath: helper.path(percentEncoded: false)),
              let info = GameProcesses.info(of: pid), let command = command(for: info, helper: helper) else { return }
        let process = Process()
        process.executableURL = URL(filePath: command.executable)
        process.arguments = command.arguments
        process.environment = command.environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
