# Cartouche decompression and drop classification research

## Recommendation

Use a bundled, arm64 + x86_64 libarchive build (libarchive 3.7.x or newer, reviewed/pinned and built with RAR and 7z support) behind a small Swift wrapper, with a separately licensed RAR backend only if broad RAR compatibility is a hard requirement. Do not treat Apple's `/usr/bin/bsdtar` as a complete solution: its linked libarchive handles common formats, but does not promise reliable RAR5/multivolume/solid/encrypted-RAR support; encrypted RAR is not a realistic supported case. libarchive is BSD-2-Clause and fits free distribution/open-source. 7-Zip's LGPL + unRAR restriction is incompatible with a general-purpose free/open-source RAR-capable app under its stated restrictions; unrar source has a proprietary license. XADMaster is LGPL, but evaluate maintenance, integration, and feature coverage before choosing it. If RAR support must be robust, investigate an LGPL-compatible implementation such as XADMaster or make RAR unsupported with a clear error rather than silently relying on system behavior.

## Evidence and local checks

Local machine reports macOS 27.0 (26A428), not macOS 15 or 26, so these checks cannot establish versions on those releases. `/usr/bin/bsdtar --version` output:

```text
bsdtar 3.5.3 - libarchive 3.7.4 zlib/1.2.12 liblzma/5.4.3 bz2lib/1.0.8
```

A synthetic ZIP was created under `/tmp`, listed and extracted successfully with `/usr/bin/bsdtar -tf/-xf`; test files were removed. This only verifies ordinary ZIP extraction, not ZIP64 specifically. No RAR fixture was fabricated and no software installed. Homebrew 7z present locally reports 7-Zip 17.05/p7zip 17.06; not representative of macOS system support.

Apple's OS ships a private/system libarchive, and `/usr/bin/bsdtar` version is not a reliable proxy for the library version on another OS release. To establish macOS 15 and 26 versions, run `sw_vers` and inspect `/usr/bin/bsdtar --version` on those OS images. Do not hard-link to `/usr/lib/libarchive.2.dylib` without checking SDK availability, ABI and App Store/sandbox implications. System library means OS-update variability and no guaranteed app-specific fixes.

libarchive's format matrix is the authority for support: https://github.com/libarchive/libarchive/wiki/LibarchiveFormats . It supports ZIP/ZIP64, 7z and common LZMA/LZMA2 methods; RAR support is limited/conditional and should not be equated with unrar's full feature set. RAR5 support varies by libarchive version; multi-volume/solid/encrypted RAR have significant limitations. Verify against real fixtures on the selected pinned build before claiming support. 7z BCJ2 and codec details also depend on build configuration. References: https://www.libarchive.org/ ; https://github.com/libarchive/libarchive ; 7-Zip licensing: https://www.7-zip.org/license.txt ; XADMaster: https://github.com/MacPaw/XADMaster (LGPL family; inspect exact license in chosen revision). unrar licensing: https://www.rarlab.com/rar_add.htm .

## Safe Swift backend design

Implement `DropClassifying` as an actor or a `Sendable` service that delegates archive I/O to a narrow C API wrapping libarchive (`archive_read_*`, `archive_write_disk_*`). Never invoke shell `bsdtar` with interpolated user paths. Request security-scoped access for dropped URLs where required. Probe/list first, then extract in bounded chunks; emit `DropProgress` bytes processed/total (archive compressed size is only an estimate of expanded work), checking `Task.isCancelled` between reads/writes. Cancellation closes readers and removes the partial staging directory.

Use a fresh staging directory under the destination parent/volume, canonicalize every archive entry and reject absolute paths, `..`, drive-like prefixes, NULs, and paths escaping the staging root. Reject symlinks/hardlinks or ensure their resolved targets remain inside the root; safest initial policy is to disallow links and special files. Create files with no-follow semantics, avoid restoring ownership/permissions, and defend against pre-existing symlink components. Enforce configurable limits for entry count, expanded bytes, path length and compression ratio. Preflight free space with `volumeAvailableCapacityForImportantUsage` (advisory only; reserve headroom; still handle ENOSPC). After successful extraction, atomically rename staging into a unique final folder on the same volume; never overwrite existing content. Keep partial extraction isolated and clean on errors. Password-protected archive errors map to `.passwordProtected`; unsupported format/codec and corruption map separately.

## Detection and `DropClassifying`

For each dropped URL: distinguish directory, archive signature/extension, executable installer, and ROM. For `.zip`, `.rar`, `.partN.rar`/`.r00`, `.7z`, use signatures plus multipart grouping (do not independently extract each volume); classify split-volume archives as a unit and report missing volumes. Folder inputs skip extraction. ROM archives extract to staging and recursively classify contents; mixed results should aggregate installer/game/ROM findings rather than stop at first match.

Installer detection should reuse InstallerKit's `PartScanner`, `ExeScan`, `DroppedFolder`, and `ExternalUnpacker` where present. Treat an executable as installer only with installer evidence (Inno/NSIS signatures, setup naming/context, companion `.bin` files); generic `.exe` can be a game executable. Group companions and return one `DroppedInstaller` with parts count. Existing installed-game folder inference should prefer known manifests (`steam_appid.txt`, Steam metadata) and likely executables, calculate folder bytes, and respect external volumes. ROM classification should combine extension allowlists with header/magic checks for known formats; extension-only is weak evidence and unknowns belong in `DroppedROMs.unknown`. Add archive-of-ROMs handling and mixed batches. Avoid claiming ROM console identification from extension where ambiguous; expose confidence/unknown for UI decisions.

`DropClassifying.classify(_:progress:) async throws -> DropResult` already supports this shape. Make extraction destinations deterministic/retained for subsequent import actions (not ephemeral temp cleanup before the UI consumes URLs). Ensure cancellation and errors become appropriate `DropFailure`, rather than `DropModel`'s broad `.nothingRecognized` fallback; consider refining that contract later.

## Source links

- libarchive: https://www.libarchive.org/ and https://github.com/libarchive/libarchive/wiki/LibarchiveFormats
- 7-Zip license: https://www.7-zip.org/license.txt
- XADMaster: https://github.com/MacPaw/XADMaster
- RAR/unrar license: https://www.rarlab.com/rar_add.htm
- Apple volume capacity API: https://developer.apple.com/documentation/foundation/urlresourcekey/volumeavailablecapacityforimportantusagekey
