# Evidence

## Verified local recipe — 2026-10-20, about 23:55

Source inspected: /tmp/carx-lab/evidence/final-verify-2026-10-20.txt.

```text
fg01 rerun3 exit=0; verify-game.py: 906 manifest rows, 905 ok, 1 'missing' = malformed manifest line (wildcard path, junk hash), 0 mismatch, 22,703,585,753 bytes, CarX Street.exe present.
```

The maintainer reports the recipe as CLS Init_MapFile_ driver plus unarc.dll FreeArcExtract under WineHQ 11.18, with no setup.tmp or ISDone. The final-verification file confirms the extracted-file counts, size and executable presence; it is not a process trace. Preserve process evidence separately when verifying the app path.

Result: 905/905 real files MD5-verified, zero mismatches, 22,703,585,753 bytes, CarX Street.exe present. Of 906 manifest rows, one is a malformed wildcard row with a junk hash. It is not counted as a missing real file.

Scope: verified local recipe only. App implementation is merged in main 3bb5921; end-to-end app verification remains pending. Unsupported recipes and actual app process behavior still need evidence. No successful game launch is claimed.

## Merged app implementation (3bb5921)

Source changes include helpers/unarc-driver.c, built by `make unarc-driver` with mingw and staged into the payload. InstallerKit DirectUnpack selects the path only when the Inno file list includes tmp/unarc.dll, tmp/arc.ini and cls-*; no password is present; and every .bin is signature-checked as a FreeArc part. Otherwise selection uses the setup path.

The engine extracts {tmp}/{app} with innoextract, patches CLS.ini, runs the driver per part with bytes-written progress, copies {app}, verifies MD5, scans runtimes and asks for the exe. Cancellation kills only the affected prefix. DirectUnpackTests and DirectUnpackFlowTests were added; this documentation update did not run them.

Known gap: a missing driver or failed part has no automatic fallback yet. Selection-time fallback is not failure recovery. The verified-installs pass must add that behavior and ADR 0026 verification interaction. Lost in Random is the next app end-to-end test; no result is claimed here.

Bundled innoextract is Homebrew 1.9, supporting Inno through 6.2.2. Do not infer support for newer Inno versions from generic archive support.
