# 0023. Bundled libarchive and shared drop classification

## Status

Accepted, 2026-10-20. Supersedes ADR 0016 in part: the decompressor dependency and license are now selected. Implementation is in progress on `phase/archives`.

## Context

The shared import flow needs predictable archive support on every supported macOS version. System libarchive and bsdtar vary with the OS. RAR coverage is not equivalent across implementations and must be tested rather than assumed.

## Decision

Bundle a pinned libarchive build under BSD-2-Clause, universal arm64 and x86_64, behind a Swift wrapper in InstallerKit. Never use system libarchive or bsdtar for this feature. The exact version and source hash must be recorded by the implementation before release.

Target formats are zip/zip64, 7z, tar.*, and RAR4/RAR5, including multi-volume and solid archives only as far as the pinned libarchive build reads them. Verify that coverage with fixtures and the user-supplied real RAR archive. Do not claim complete RAR support before verification. Refuse encrypted archives with a clear message.

A shared DropClassifier backend implements the existing UI DropClassifying protocol. Archives are extracted then classified. The backend distinguishes installers, installed-game folders, ROMs, ROM archives and mixed inputs, and feeds the existing UI rather than introducing a second import UI. Classification does not execute dropped programs. Extraction must keep paths inside its staging root and preserve user source files.

## Alternatives rejected

- System libarchive or bsdtar: OS-dependent behavior, not the pinned bundled backend.
- 7-Zip: the unRAR restriction does not meet the selected licensing policy.
- unrar: proprietary license.
- XADMaster: keep as a later option only if tested libarchive RAR coverage is insufficient.

## Consequences

Ship the selected libarchive source pin, build recipe and license notice. Verify both architecture slices. Unsupported RAR variants, missing volumes, corrupt archives and encrypted archives must fail clearly, not silently fall back to system tools. Keep fixture results distinct from the real-archive result. Research: `.claude/reports/research-decompressor.md`; implementation and verification remain in progress.
