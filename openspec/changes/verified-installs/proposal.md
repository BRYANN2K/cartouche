# Verified, or fall back

Status: policy accepted; UI merged in main 7f8773b. Verification engine, live backend wiring and integrated policy checks remain pending.

## Why

Successful extraction and executable presence do not prove a complete installation. Optimizations must preserve output.

## What changes

ADR 0026 amends ADR 0025: full verification uses a shipped checksum list or archive CRC and always runs; script presence/sizes alone gives “verified (sizes)”; unavailable evidence allows “Installed, not verified” with a discreet badge and panel line. Stop marks not verified; there is no skip checkbox. Verify Files… permits later checks.

Mismatch shows Retry with the standard method (default), Keep Anyway (advanced; not verified and mismatches logged), and Cancel. Retry selects shipped helpers/original settings, with guided real-installer execution last. Exact helper hash allowlists, byte-identical local regression and no corpus uploads still apply.

## Not covered by this change

The detection decision tree in research-verified.md is approved by ADR 0028. This change approves verification, fallback order and optimization constraints, not any unrecorded helper hash.
