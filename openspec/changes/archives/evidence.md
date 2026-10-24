# Archive backend implementation evidence

Main 95b4e47 merges bundled libarchive 3.8.9 with xz 5.8.4 and zstd 1.5.7, universal arm64+x86_64. Exact source URLs and SHA-256 pins are in installer/libarchive/pins; build recipe is installer/libarchive/build.sh. CArchive is the C shim. ArchiveExtractor handles volume sets, path sanitisation, staging and disk-space checks. InstallerKit DropClassifier implements backend classification.

The integration owner reports 155 installer tests, including RAR4/RAR5, solid and multi-volume fixtures from libarchive’s BSD-2-Clause test suite. Fixture provenance and individual variants are listed in installer/Tests/InstallerKitTests/Fixtures/archives/README.md. This docs update did not rerun those tests. Fixture results are not a promise of all RAR variants.

App wiring is not merged: the adapter remains in installer/AppAdapter/DropClassifierAdapter.swift. The Add Games UI therefore still lacks the live classifier. Real-hardware checks and the user-supplied real RAR test remain pending. ADR 0026 verification interaction remains separate work.
