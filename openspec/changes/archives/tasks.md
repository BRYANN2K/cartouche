# Tasks

- [x] Pin libarchive source version and hash; include build recipe and BSD-2-Clause notice. (implementation merged in 95b4e47).
- [x] Build and bundle arm64+x86_64 slices without a system libarchive/bsdtar fallback. (implementation merged in 95b4e47).
- [x] Add the narrow InstallerKit Swift extraction wrapper with safe staging and cancellation. (implementation merged in 95b4e47).
- [x] Wire the merged InstallerKit DropClassifier to the app’s DropClassifying protocol. (Library/Drop/DropClassifierAdapter.swift; 7b9f842 / 539fbe3.)
- [x] Handle archive extraction then classification, multipart sets and mixed inputs. (implementation merged in 95b4e47).
- [x] Refuse encrypted archives with a clear error; report missing volumes and unsupported variants distinctly. (implementation merged in 95b4e47).
- [x] Test zip/zip64, 7z, tar.*, RAR4/RAR5, multi-volume and solid variants with recorded expected outputs. (implementation merged in 95b4e47).
- [ ] Verify the user-supplied real RAR archive and record its result separately.
- [x] Test path/link escape rejection, source preservation and cancellation cleanup. (implementation merged in 95b4e47).
- [ ] Record fresh evidence for every archive-import scenario and obtain review.
- [ ] Apply ADR 0026 verification levels, mandatory full checks/Stop, mismatch choices and later Verify Files…; retain ADR 0025 helper-hash/output-equivalence rules; see verified-installs.
