# 0028. Detect installers by static inspection, with evidence and confidence

## Status

Accepted, 2026-10-21. Approves the corrected decision tree in `.claude/reports/research-verified.md`, which ADRs 0025 and 0026 left proposed; their other rules are unchanged. Refines the classification rules of ADRs 0016, 0017 and 0023 without changing them.

## Context

Installer-detection claims were checked against format documentation in research-verified.md. Several earlier assumptions failed verification: filenames, brand names and the `.bin` suffix are weak evidence; innoextract 1.9 supports Inno 1.2.10–6.2.2 and not 6.3.x/6.4.0; innoextract never runs installer scripts and does not reliably extract optional components; external decompressor helpers (ISDone.dll, unarc.dll, CLS-*.dll) have no canonical public API; InstallShield sidecars and MSI container signatures are clues, not proof.

## Decision

Classification uses static inspection only — filenames, sizes, magic bytes, PE structure and overlay, archive parser results, sidecars and volume families — and never executes a dropped file to classify it. Every classification reports its evidence and a confidence level.

1. An existing game directory is identified by its executable plus corroborating markers (Unity `_Data`, Unreal layout, Steam `appmanifest`, Epic `.egstore`), reported as evidence that may be copied or stale.
2. An Inno candidate is checked with `innoextract --data-version`/`--info` and `--list` in non-writing mode. The recorded supported range is innoextract 1.9 covering Inno 1.2.10–6.2.2. A newer or unknown data version is classified as Inno-like and unsupported, not as a generic archive. Optional content is not inferred from filename lists.
3. An Inno installer referencing runtime decompressor helpers (ISDone.dll, unarc.dll, CLS-*.dll) is classified as an installer requiring runtime behavior; static extraction alone may not reproduce it.
4. Other installers — validated NSIS structure, corroborated InstallShield clue sets, a parsed MSI database — go to a guided Wine install, never silent execution.
5. Archives and SFX packages are validated by an archive parser over the complete part set; a missing required volume blocks extraction. A generic executable plus archive stays SFX/ambiguous until evidence says more.
6. Extracted contents matching an installed-game layout are a portable build; redistributables are never run automatically.
7. Ambiguous or conflicting evidence is shown to the user as observed facts with a confidence level, and the user decides. An unknown executable is never run by default.

## Alternatives rejected

- Executing a file to classify it.
- Inferring format, optionality or completeness from filenames, brand names or the `.bin` suffix alone.
- Treating innoextract 1.9 as covering Inno 6.3.x/6.4.0.
- Assuming an installer can be fully reproduced without running it when it needs runtime decompressor helpers.
- Silently executing an unrecognized installer under Wine.

## Consequences

The windows-installer spec gains a static-classification requirement. Detection code must expose the evidence behind each result so the UI can show confidence and ask the user. License clearance for helper codecs (FreeArc, SREP, XTool, LOLZ, Magic2, Oodle) is unchanged and still required before any redistribution.
