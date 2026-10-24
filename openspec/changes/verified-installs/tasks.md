# Tasks

## UI merged in 7f8773b

- [x] Add GameVerificationPresenting protocol and display states (full, sizes, not verified).
- [x] Add status badge and game-panel line for not-verified and size-verified output.
- [x] Add Verify Files… menu action and progress UI with Stop; no skip-verification checkbox.
- [x] Add mismatch sheet: Retry with the Standard Method (default), Keep Anyway and Cancel.

## Engine and integration

- [x] Supply a live backend through GameVerificationPresenting; the default environment value is unavailable (nil).
- [x] Persist separate installed/verification state and select full checksum/CRC, partial presence/sizes, or unavailable evidence correctly.
- [x] Always run available full checks; Stop must persist not verified.
- [x] Implement later Verify Files…, including a supplied checksum list, beyond fixture UI behavior.
- [x] Implement Keep Anyway’s not-verified state and mismatch log, and Cancel behavior in the live engine.
- [x] Route Retry through shipped helpers/original settings, then guided installer under Wine as last resort.
- [x] Enforce exact helper-hash allowlists and byte-identical local regression output; never upload corpus files or verification data.
- [x] Record integrated scenario evidence and review (detection tree approved by ADR 0028).
