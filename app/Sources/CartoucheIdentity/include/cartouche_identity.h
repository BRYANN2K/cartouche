// Cartouche's names on disk and inside Steam, defined once. The app reads these
// through SupportPaths, the dylib and the Makefile through this header. Shell and
// JavaScript cannot include a header, so IdentityTests checks their copies.
#ifndef CARTOUCHE_IDENTITY_H
#define CARTOUCHE_IDENTITY_H

// Folder name under Application Support, Caches and Logs
#define CARTOUCHE_DIR_NAME "Cartouche"

// The same folders relative to the home folder, for C callers
#define CARTOUCHE_SUPPORT_DIR "Library/Application Support/" CARTOUCHE_DIR_NAME
#define CARTOUCHE_LOGS_DIR "Library/Logs/" CARTOUCHE_DIR_NAME

// Prefix of the names Cartouche puts inside Steam: files in a game's prefix, the
// template cache, the library filter key. Launch option variables use CARTOUCHE_.
#define CARTOUCHE_STEAM_PREFIX "cartouche"

// Prefix of Cartouche's compatibility tool names. Steam maps Cloud save paths into
// the prefix only for tools whose name contains "proton".
#define CARTOUCHE_TOOL_PREFIX "cartouche-proton"

// Files in the data folder the app writes and the dylib reads (P3): one Steam tool per
// runner and graphics backend pair, and the per-game tool choices Steam is asked to make.
// Backends and per-game variables sit in folders the run script reads.
#define CARTOUCHE_BACKEND_TOOL_LIST "backend-tools"
#define CARTOUCHE_COMPAT_REQUESTS "compat-requests"
#define CARTOUCHE_BACKENDS_DIR "backends"
#define CARTOUCHE_SETUPS_DIR "setups"

// The frame counter injected into Windows games, and the folder its sessions go to (P8)
#define CARTOUCHE_FPS_COUNTER_NAME "fps-counter.dylib"
#define CARTOUCHE_PERFORMANCE_DIR "performance"

// The local agent transport (P11): a Unix socket under the data folder the
// bundled cartouche-mcp helper connects to; the app is its only server.
#define CARTOUCHE_AGENT_DIR "agent"
#define CARTOUCHE_AGENT_SOCKET "agent/mcp.sock"

// The dylib injected into Steam.app
#define CARTOUCHE_DYLIB_NAME "cartouche.dylib"

// NotProton injects the same Steam under these names. Cartouche detects them and
// leaves them alone.
#define CARTOUCHE_OTHER_DYLIB_NAME "notproton.dylib"
#define CARTOUCHE_OTHER_STEAM_PREFIX "notproton"

// NotProton's pristine copy of Steam's plist, inside its own data folder
#define CARTOUCHE_OTHER_PLIST_BACKUP "backups/Info.plist.before-notproton"

#endif // CARTOUCHE_IDENTITY_H
