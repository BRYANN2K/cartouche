import Foundation

// Our library: the temporal scaler's chain and the in-game HUD. The game's profile sets
// CARTOUCHE_FRAMEGEN=1 when it needs either, and the game starts with the library once the
// runner's loader has shown it accepts it. Frame interpolation stays off (ADR 0031 keeps it out
// of the UI). The library goes first in DYLD_INSERT_LIBRARIES, so the frame counter wraps it.
enum FrameGeneration {
    static let variable = "CARTOUCHE_FRAMEGEN"
    static let interpolateVariable = "CARTOUCHE_FRAMEGEN_INTERPOLATE"
    static let statsVariable = "CARTOUCHE_FRAMEGEN_STATS"
    static let temporalVariable = "CARTOUCHE_FRAMEGEN_TEMPORAL"
    static let marker = "# Cartouche frame generation"

    static func launcherLines(library: URL = SupportPaths.framegen, stats: URL) -> [String] {
        """
        \(marker)
        if [ "${\(variable):-0}" = 1 ]; then
          fg_library=\(GameLauncher.quote(library.path(percentEncoded: false)))
          fg_stats=\(GameLauncher.quote(stats.path(percentEncoded: false)))
          fg_marker="${TMPDIR:-/tmp}/cartouche-framegen-$$"
          if [ -f "$fg_library" ] && DYLD_INSERT_LIBRARIES="$fg_library" CARTOUCHE_FRAMEGEN_PROBE="$fg_marker" \\
            "$WINELOADER" --version > /dev/null 2>&1 && [ -s "$fg_marker" ]; then
            export DYLD_INSERT_LIBRARIES="$fg_library${DYLD_INSERT_LIBRARIES:+:$DYLD_INSERT_LIBRARIES}"
            export \(interpolateVariable)=0
            export CARTOUCHE_FRAMEGEN_DIR="${CARTOUCHE_FRAMEGEN_DIR:-$fg_stats}"
            echo "framegen: on for this launch"
          else
            echo "framegen: refused by this runner"
          fi
          rm -f "$fg_marker"
        fi
        """.components(separatedBy: "\n")
    }
}
