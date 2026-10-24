# Direct extraction for installers with external unpackers

Status: recipe verified on one local test case; app implementation merged in main 3bb5921. App end-to-end verification and automatic failure fallback remain pending. ADR 0017 is the accepted decision.

## Why

Some installer wrappers fail although their external parts can be read directly. A supported recipe should not need setup.tmp or ISDone.

## What changes

Integrate Cartouche’s own unpacker driver for verified formats. Keep unknown formats on the normal installer path or report unsupported extraction clearly. Do not infer format support from .bin alone.

## Evidence boundary

The CLS Init_MapFile_ plus unarc.dll FreeArcExtract recipe extracted CarX Street under WineHQ 11.18. All 905 real files passed MD5 verification; 22,703,585,753 bytes; executable present. The 906th manifest row is malformed, not a missing real file. See evidence.md. This is not evidence that the app integration is done or that the game launched.

## Verification policy update (2026-10-21)

ADR 0026 amends ADR 0025. Full checksum/CRC checks are mandatory; script presence/sizes give partial verification; unavailable evidence allows Installed, not verified. Mismatch offers Retry with the standard method (default), Keep Anyway (advanced; not verified and logged), and Cancel. Retry starts shipped helpers/original settings, with guided real-installer execution last. Exact helper-hash matches and byte-identical local regression output still apply. See verified-installs. The detection tree is approved by ADR 0028.
