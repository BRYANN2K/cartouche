# Tasks

- [x] Verify the direct recipe on the CarX Street local test case and record all real-file checksums.
- [x] Integrate recipe selection and the Cartouche-owned driver in the app (main 3bb5921).
- [ ] Verify the app path never executes setup.tmp or ISDone using process evidence.
- [ ] Handle progress, cancellation, failure and safe output cleanup without deleting source parts.
- [ ] Test unknown formats and the normal-installer/unsupported fallback.
- [ ] Record fresh evidence for all direct-unpack scenarios and obtain review before marking app integration complete.
- [ ] Apply ADR 0026 verification levels, mandatory full checks/Stop, mismatch choices and later Verify Files…; retain ADR 0025 helper-hash/output-equivalence rules; see verified-installs.
- [x] Fall back to the original setup when the driver is missing or a part fails, on Try Again and never automatically (ADR 0034). (e4ff967 / 75f9887, merged in bc926b9; pending build and live verification.)
- [ ] Run Lost in Random end to end in the app and record fresh verification evidence.
