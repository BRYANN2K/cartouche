# Bundled archive import and shared classifier

Status: archive backend merged in main 95b4e47; app adapter is not wired and real-hardware/user-archive checks remain pending.

## Why

Users should drop their own archives and game files without installing another extractor. OS-provided tools do not guarantee consistent format support.

## What changes

Bundle pinned universal arm64+x86_64 libarchive (BSD-2-Clause) behind an InstallerKit Swift wrapper. Do not use system libarchive or bsdtar. Feed the existing UI DropClassifying protocol through a shared DropClassifier: archives extract then classify; other classes are installer, installed-game folder, ROMs, ROM archives and mixed input.

Target zip/zip64, 7z, tar.*, RAR4/RAR5; multi-volume and solid RAR only as far as the chosen build reads them. Verify fixtures and the user-supplied real RAR before making coverage claims. Refuse encrypted archives clearly.

## Alternatives

7-Zip rejected for the unRAR restriction; unrar rejected as proprietary. XADMaster remains a later option if verified RAR coverage is insufficient.

## Evidence

Research is in .claude/reports/research-decompressor.md. It does not prove the selected bundled build’s format coverage. Source version/hash and format results remain implementation evidence, not assumptions.

## Verification policy update (2026-10-21)

ADR 0026 amends ADR 0025. Full checksum/CRC checks are mandatory; script presence/sizes give partial verification; unavailable evidence allows Installed, not verified. Mismatch offers Retry with the standard method (default), Keep Anyway (advanced; not verified and logged), and Cancel. Retry starts shipped helpers/original settings, with guided real-installer execution last. Exact helper-hash matches and byte-identical local regression output still apply. See verified-installs. The detection tree is approved by ADR 0028.
