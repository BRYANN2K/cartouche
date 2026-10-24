# Direct unpacker verification: CarX Street

Recorded 2026-10-20, about 23:55. This is verified local recipe evidence for ADR 0017, not completed app integration.

## Recipe and environment

The direct recipe uses a CLS `Init_MapFile_` driver and `unarc.dll` `FreeArcExtract` under WineHQ 11.18. It does not run `setup.tmp` or ISDone.

## Result

- Extraction exited with status 0.
- All 905 real files passed MD5 verification; zero checksum mismatches.
- The manifest contains 906 rows. Its extra row has a malformed wildcard path and junk hash, not a missing real file.
- Verified output size: 22,703,585,753 bytes (about 22.7 GB).
- `CarX Street.exe` is present. Executable presence does not establish a successful game launch.

Original local evidence: `/tmp/carx-lab/evidence/final-verify-2026-10-20.txt`. Its contents were inspected when writing this summary:

```text
fg01 rerun3 exit=0; verify-game.py: 906 manifest rows, 905 ok, 1 'missing' = malformed manifest line (wildcard path, junk hash), 0 mismatch, 22,703,585,753 bytes, CarX Street.exe present.
```

## Scope and remaining work

The result verifies this recipe on this test case. It does not prove support for all external-unpacker formats, every runner or encrypted archives. App implementation is merged; end-to-end app verification and automatic failure fallback remain pending. The app still needs routing, safe output handling, progress, cancellation, failure behavior and evidence from its own path before this feature can be marked complete.
