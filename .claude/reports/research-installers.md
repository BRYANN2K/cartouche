# Installer research for Cartouche

**Evidence labels:** Local observations below are **verified locally**; ecosystem descriptions are **from knowledge, to verify** (installer formats evolve; use corpus testing rather than assume branding proves format). No installer was run and no user files were changed.

## DropClassifier decision tree

1. **Verified locally — inspect without execution.** Inventory extension, magic/header, directory contents, signatures, and archive part family. Never infer solely from filename.
2. **Already-installed game folder (high confidence):** Unity `*_Data` matching an EXE, Unreal `Engine/Binaries/Win64` plus game binaries, game package files (`.pak/.pck/.vpk`), Steam API DLL, large game EXE; launcher metadata such as `steamapps/appmanifest_*.acf` or Epic `.egstore` strengthens. If also setup executable, strong installed-game markers should prompt user choice rather than auto-install.
3. **Inno (high):** `innoextract --info` succeeds and/or PE strings include Inno Setup. Run its safe metadata/list operations. If plain payload, expose extraction/install path. If external unpacker evidence (ISDone/unarc/CLS helpers or FreeArc magic) exists, classify “Inno + runtime decompressor” and offer guided Wine install, not innoextract-only.
4. **Other recognizable installer (medium/high):** NSIS marker, InstallShield `data1.cab`/`.hdr`, MSI/WiX, or known installer family headers -> guided Wine installer mode. Don’t pretend they are extractable by innoextract.
5. **Archive (high):** ZIP/RAR/7z/ISO magic or archive parser; detect multipart naming and report missing segments. Inspect contents only in scratch. If contents are a game folder, classify portable build.
6. **Single EXE (low/medium):** PE without installer signature, no neighboring data, no game markers: ambiguous. Ask user; guided “Run installer in Wine” fallback.
7. **ROM (medium):** recognized console ROM extensions/magic, no PE/game install structure; route to emulator flow, never Wine installer.
8. **Uncertain/contradictory evidence:** show detected facts/confidence and offer guided “Run the installer in Wine”; do not silently extract or execute.

## Technologies and payload patterns

All claims in this section are **from knowledge, to verify** unless explicitly marked local. “.bin” is not a format: it can be Inno slice, arbitrary data, FreeArc archive, or split archive. Use signatures/parser and metadata, not suffix alone.

- **Inno Setup:** PE setup executable embeds setup data and/or references external slices, commonly `setup-1.bin`, `setup-2.bin`, `setup-*.bin`; GOG commonly `setup_<game>_<version>_(... ).exe` plus `...-1.bin` slices. `innoextract --info/--list` provides title/version/languages/file list and extraction support varies by Inno data version. Signature strings include Inno Setup; actual version is data version, e.g. locally code recognizes parsed `setup data version`. Plain Inno is the innoextract use case.
- **Inno + ISDone/ISArcExtract:** Inno script may copy helpers to `{tmp}` and invoke ISDone/ISArcExtract/unarc; helper inventory includes `unarc.dll`, `ISDone.dll`, `CLS-*.dll` (srep, lolz, xtool, precomp, oodle/oo2core and others), `arc.ini`/`CLS.ini`, `facompress`. Payload may be `.bin`, `.arc`, `.dat`, `.001` or arbitrary names. File list from Inno plus helper filenames and FreeArc magic (`ArC`) indicate this; external decompression is runtime script behavior, so generic extraction is not equivalent.
- **NSIS:** PE/Nullsoft signature; embedded payload, sometimes external `.nsis`/data file or plugin-based extraction. Innoextract does not apply.
- **InstallShield:** setup launcher and `data1.cab`, often `data1.hdr`/`.hdr`, `setup.ini`, numbered CABs; older InstallShield variants differ. CAB + header pairing is evidence, not definitive alone.
- **WiX/MSI:** `.msi` Windows Installer database, embedded or external `.cab`; may be bootstrapper EXE. MSI is not a game archive; use Wine msiexec or guided mode.
- **InstallAware, Smart Install Maker, Setup Factory, Advanced Installer:** installer-family PE signatures/strings and vendor-specific sidecar data; often embedded or numbered `.bin/.cab/.dat`. Treat as opaque installer pending dedicated parser/fixtures.
- **7-Zip SFX / WinRAR SFX:** executable prefix with appended 7z/RAR archive; detect PE plus archive signatures/parser recognition, not installer brand. May be self-extractor, not game installer.
- **ZIP/RAR/7z:** parse standard archive signatures; multipart `.part1.rar`, `.r00`, `.7z.001`, `.zip.001`, etc. Require complete set before extraction; only scratch directory.
- **Portable Unity/Unreal:** folder/archive of already-built game, e.g. Unity EXE + matching `_Data`, Unreal `Engine/Binaries/Win64`, `.pak`; no setup flow required.

## Who uses what; optional choices

**From knowledge, to verify:** GOG offline game installers commonly use Inno, with executable and numbered `.bin` slices; Galaxy installations instead live in client-managed directories and metadata. Steam installed games carry `steamapps/appmanifest_<appid>.acf`; Epic commonly has `.egstore` metadata. A folder containing a game executable alone is not definitive.

Repack branding is not a reliable format classifier. FitGirl often Inno front-end + ISDone/FreeArc and `fg-*.bin`, checksum manifests (`MD5`), optional language/component payloads. DODI, ElAmigos, KaOs, Xatab, Masquerade, Chovka vary by release; technical patterns can include Inno+external decompressor, numbered/parted data, checksum files, optional components/language selections. Don’t hard-code brand assumptions. Scene-style releases often ISO containing setup and/or RAR volume sets; “pre-installed” distributions are archived game folders (e.g. SteamRIP-style RAR), not installers.

Optional payloads: Inno script `[Components]`/`[Tasks]` names, descriptions, types, flags and `[Files]` `Components`/`Tasks` predicates establish choices. `dontcopy` and `[Code]`/`CompiledCode` may stage helper/data files or custom decompression. `innoextract --list` gives file names but may not expose the full script predicates; parse/decompile script only where safely supported. Files named `fg-optional-*.bin` and MD5 manifest text are clues, not sufficient to know exact dependency. Present available choices only when script evidence supports them; missing required parts block; missing optional part should disable that option and explain. Never label a numbered gap optional based on filename guess alone.

## Local survey (verified locally)

`~/Downloads` relevant items (names/types only):
- `CarX Street [FitGirl Repack]/setup.exe`, `fg-01.bin`, `fg-02.bin`, `MD5` — Inno/repack-family candidate, likely external unpacker; not executed. Exact Inno inspection not performed here.
- `Lost in Random [FitGirl HV Repack]/setup.exe`, `fg-01.bin` through `fg-04.bin`, `MD5` — same candidate classification; not executed.
- `Hollow-Knight-Silksong-SteamRIP.com.rar` — RAR v5 verified with `file`; sibling extracted folder exists.
- `Hollow-Knight-Silksong-SteamRIP.com/Hollow Knight Silksong/` contains `Hollow Knight Silksong.exe`, matching `_Data`, plus `UnityCrashHandler64.exe` — Unity portable/already installed, verified locally by names.
- Its `_CommonRedist` includes DirectX, Visual C++ bundle, .NET, XNA and OpenAL-named installers; don’t run these as part of classification.
- Other matched extensions in Downloads were macOS `.dmg`/`NotProton.zip`, not Windows game installers.

## InstallerKit: existing coverage and gaps

**Verified locally:** `InnoInspector` calls bundled innoextract 1.9 with `--info` and `--list`; parses title, data version, languages, password indication and file paths. It infers heavy decompression from helpers. `ExternalUnpacker` detects helper names from Inno list and folder, recognizes FreeArc magic in `.arc/.bin`. `PartScanner` currently scans numbered `.bin`/`.bin.NNN`, identifies setup by name/signature, reports numeric gaps. `DroppedFolder` detects Inno/NSIS/InstallShield strings, setup-like names, Unity/Unreal/Steam API/package markers and existing programs; unwraps nested single-folder wrapper. `ChecksumManifest` reads MD5 and optional wording. `ExeScan` parses Windows shortcut data; `Analysis` composes scan/manifest/Inno/unpacker/classification.

Gaps / risks: no broad archive/container classifier for ZIP/RAR/7z/ISO/MSI/CAB; no multipart families except `.bin` numbering; no appmanifest/Epic `.egstore` marker; current folder classifier is installer-vs-installed-game only and otherwise defaults to installer, which is unsafe for ambiguous single EXEs. Signature list and 4 MiB scan are heuristic; no family-specific NSIS/InstallShield confirmation or metadata for WiX/vendor installers. Inno file-list heuristic cannot reliably read `[Components]`, `[Tasks]`, predicates, script code, or distinguish external payload dependency from mere helper presence. `PartScanner` only `.bin`; optional `.bin` gaps need semantic confirmation. No ROM route. Add confidence/evidence and explicit unknown state, rather than default installer.

## Regression corpus plan

Collect legally redistributable or internally generated fixtures; retain hashes, provenance/license, tool versions, expected classification, confidence, parts/required-vs-optional, and expected safe metadata. Include: plain embedded Inno; external-slice Inno; GOG offline Inno multi-bin; multiple Inno data versions; passworded/unsupported Inno; Inno + ISDone/FreeArc + representative CLS families and arc.ini/CLS.ini; missing required vs missing optional part; checksum manifest; NSIS embedded and sidecar; InstallShield data1.cab/hdr; MSI embedded CAB and external CAB; InstallAware, Smart Install Maker, Setup Factory, Advanced Installer; 7z SFX and WinRAR SFX; ZIP/RAR/7z/ISO single and multipart with missing volume; Unity portable, Unreal portable, Steam manifest folder, Epic `.egstore`; ambiguous single EXE; ROM fixtures by supported console. Tests must inspect only, never run arbitrary samples. Seed local cases: the two FitGirl-named folders and SteamRIP RAR/Unity folder (user files should not be copied into corpus without permission).
