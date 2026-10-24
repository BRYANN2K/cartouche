import Foundation
import InstallerKit

enum AdvancedPrefixSettings {
    static func retinaArguments(_ value: String) -> [String] {
        ["reg", "add", #"HKCU\Software\Wine\Mac Driver"#, "/v", "RetinaMode", "/t", "REG_SZ", "/d", value == "1" ? "y" : "n", "/f"]
    }

    // Call on a worker before launch, not while the game's Wine session is running.
    static func apply(wine: WineRunner, prefix: URL, environment: [String: String]) throws {
        try SetupEnvironment.prepareNVExtensions(wine: wine, prefix: prefix, environment: environment)
        let marker = prefix.appending(path: "cartouche-msync")
        if let msync = environment["WINEMSYNC"] {
            let previous = try? String(contentsOf: marker, encoding: .utf8)
            if previous != msync {
                try stopServer(wine: wine, environment: environment)
                try Data(msync.utf8).write(to: marker, options: .atomic)
            }
        }
        if let retina = environment["CARTOUCHE_RETINA"] {
            let marker = prefix.appending(path: "cartouche-retina")
            if (try? String(contentsOf: marker, encoding: .utf8)) != retina {
                try Shell.check(wine.loader.path(percentEncoded: false), retinaArguments(retina), environment: environment)
                try stopServer(wine: wine, environment: environment)
                try Data(retina.utf8).write(to: marker, options: .atomic)
            }
        }
    }

    static func stopServer(wine: WineRunner, environment: [String: String]) throws {
        let result = try Shell.run(wine.server.path(percentEncoded: false), ["-k"], environment: environment)
        guard result.succeeded || (result.status == 1 && !result.outputLost && result.stdout.isEmpty && result.stderr.isEmpty) else {
            throw CommandFailure(command: "wineserver -k", status: result.status, stderr: result.stderr)
        }
        try Shell.check(wine.server.path(percentEncoded: false), ["-w"], environment: environment)
    }

    static func launcherLines(environment: [String: String], wine: WineRunner) -> [String] {
        var lines: [String] = []
        if environment["WINEMSYNC"] != nil || environment["CARTOUCHE_RETINA"] != nil {
            lines += [
                "cartouche_stop_server() {",
                #"  cartouche_server_message=$("$WINESERVER" -k 2>&1)"#,
                "  cartouche_server_status=$?",
                #"  if [ "$cartouche_server_status" -ne 0 ] && { [ "$cartouche_server_status" -ne 1 ] || [ -n "$cartouche_server_message" ]; }; then"#,
                #"    printf '%s\n' "$cartouche_server_message" >&2"#,
                #"    return "$cartouche_server_status""#,
                "  fi",
                #"  "$WINESERVER" -w"#,
                "}",
            ]
        }
        if environment["WINEMSYNC"] != nil {
            lines += [#"msync_file="$WINEPREFIX/cartouche-msync""#,
                      #"if [ "$(cat "$msync_file" 2>/dev/null)" != "$WINEMSYNC" ]; then"#,
                      #"  cartouche_stop_server || exit $?"#,
                      #"  printf '%s' "$WINEMSYNC" > "$msync_file" || exit $?"#, "fi"]
        }
        if let retina = environment["CARTOUCHE_RETINA"] {
            lines += [#"retina_file="$WINEPREFIX/cartouche-retina""#,
                      #"if [ "$(cat "$retina_file" 2>/dev/null)" != "$CARTOUCHE_RETINA" ]; then"#]
            lines.append(([wine.loader.path(percentEncoded: false)] + retinaArguments(retina)).map(GameLauncher.quote).joined(separator: " ") + " || exit $?")
            lines += [#"cartouche_stop_server || exit $?"#,
                      #"printf '%s' "$CARTOUCHE_RETINA" > "$retina_file" || exit $?"#, "fi"]
        }
        if environment["DXMT_ENABLE_NVEXT"] == "1" {
            lines += [#"old_ifs=$IFS; IFS=:"#, #"for dir in $WINEDLLPATH; do"#,
                      #"  for dll in nvapi64.dll nvngx.dll; do"#,
                      #"    [ ! -f "$dir/$dll" ] || cp -f "$dir/$dll" "$WINEPREFIX/drive_c/windows/system32/$dll" || exit $?"#,
                      "  done", "done", "IFS=$old_ifs"]
        }
        return lines
    }
}
