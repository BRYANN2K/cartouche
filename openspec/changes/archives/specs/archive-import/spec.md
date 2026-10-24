# Archive import delta

## ADDED Requirements

### Requirement: Pinned bundled archive backend
InstallerKit SHALL expose a Swift wrapper around a bundled, pinned libarchive build under BSD-2-Clause, with arm64 and x86_64 slices. Archive import SHALL NOT load system libarchive or invoke system bsdtar. The source version, source hash, build recipe and license notice SHALL be recorded before release.

#### Scenario: Both supported architectures
- **WHEN** the bundled backend is inspected and archive fixtures run on each supported architecture
- **THEN** both arm64 and x86_64 slices are present and extraction uses the pinned bundled build, not system libarchive or bsdtar

### Requirement: Verified format coverage
The backend SHALL target zip/zip64, 7z, tar.*, and RAR4/RAR5. Multi-volume and solid RAR support SHALL be limited to variants the pinned build demonstrably reads. Coverage SHALL be recorded from fixtures and the user-supplied real RAR archive before claiming support. Unsupported formats or codecs, corrupt input and missing volumes SHALL return clear errors without a fallback to system tools. Encrypted archives SHALL be refused with a clear message.

#### Scenario: Supported fixtures
- **WHEN** supported zip/zip64, 7z, tar.*, RAR4 and RAR5 fixtures are extracted
- **THEN** output matches expected files and bytes, with results recorded per format and per multi-volume or solid variant tested

#### Scenario: Real RAR verification
- **WHEN** the selected build is tested with the user-supplied real RAR archive
- **THEN** evidence records whether extraction succeeds and any coverage limit; fixture success alone does not count as this verification

#### Scenario: Encrypted archive
- **WHEN** the user drops an encrypted archive
- **THEN** extraction is refused with a clear encrypted-archive message and no partial import is presented as ready

#### Scenario: Missing or unsupported RAR volume
- **WHEN** a multi-volume RAR set lacks a required volume or uses a variant the backend cannot read
- **THEN** the flow reports the missing volume or unsupported variant and does not invoke a system extractor

### Requirement: Shared drop classification
A DropClassifier backend SHALL feed the existing UI DropClassifying protocol. It SHALL classify installers, installed-game folders, ROMs, ROM archives and mixed inputs. Archive inputs SHALL be extracted then classified; multipart archives SHALL be treated as a set rather than independent complete archives. Classification SHALL NOT execute dropped programs.

#### Scenario: Archive then classify
- **WHEN** an archive contains an installed game, installer or ROM files
- **THEN** the backend extracts it and supplies the corresponding classification and usable extracted paths through the existing DropClassifying protocol

#### Scenario: Mixed inputs
- **WHEN** the dropped batch contains installer files, an installed-game folder and ROMs
- **THEN** all recognized classes are returned to the existing UI rather than silently stopping after the first class

### Requirement: Safe extraction and source preservation
Extraction SHALL write inside an isolated staging root without overwriting user source files or allowing archive entries or links to escape that root. Cancellation and extraction failure SHALL clean partial output without deleting source archives. Successful output SHALL remain available while the import UI consumes it.

#### Scenario: Escaping archive path
- **WHEN** an archive entry or link would resolve outside the extraction root
- **THEN** extraction rejects it and writes nothing outside that root

#### Scenario: Cancel extraction
- **WHEN** the user cancels extraction
- **THEN** partial output is cleaned and the source archive remains unchanged
