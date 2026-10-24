# 0025. Verify installation output or fall back

## Status

Accepted, 2026-10-21. Extends ADRs 0017 and 0023. Implementation and regression verification are pending. The detection decision tree in research-verified.md remains proposed, not approved.

## Context

A successful extractor exit or an executable’s presence does not prove a complete installation. Faster extraction must not change the installed files.

## Decision

Mark a game installed only after output verification. Use the shipped MD5/checksum manifest when present. Otherwise require the archive’s integrity checks, including FreeArc CRC through unarc where applicable, plus the installer script’s file list and sizes. Do not treat missing verification evidence as success.

On verification failure or mismatch, automatically retry with the installer’s shipped helpers and original settings. If that still fails, offer a guided run of the real installer under Wine as the last resort. The same verification gate applies before marking its result installed.

Optimizations may change speed only, never output. A native helper replacement is permitted only for an exact known helper version matched by a hash allowlist. Unknown helpers use the shipped Windows helper. Each optimization must produce byte-identical output on a local regression corpus, including CarX Street, Lost in Random and the user’s Silksong RAR where applicable. These are the user’s own files; corpus files and verification data never leave the Mac.

## Alternatives rejected

- Mark installed because extraction exited successfully or an exe exists.
- Trust an optimization without output comparison.
- Replace unknown helper versions heuristically.
- Upload the regression corpus or its verification data.

## Consequences

The installer, archive and direct-unpack specs share the verification gate and fallback order. Existing recipe evidence does not prove this whole policy is integrated. Record verification and fallback outcomes without claiming the proposed detection tree is accepted. No timeout, helper hash or new checksum algorithm is chosen by this ADR.
