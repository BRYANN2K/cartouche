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

// The dylib injected into Steam.app
#define CARTOUCHE_DYLIB_NAME "cartouche.dylib"

// NotProton injects the same Steam under these names. Cartouche detects them and
// leaves them alone.
#define CARTOUCHE_OTHER_DYLIB_NAME "notproton.dylib"
#define CARTOUCHE_OTHER_STEAM_PREFIX "notproton"

#endif // CARTOUCHE_IDENTITY_H
