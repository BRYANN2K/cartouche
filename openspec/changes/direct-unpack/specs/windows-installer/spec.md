# Direct unpack delta

## ADDED Requirements

### Requirement: Direct extraction for supported external unpackers
For supported installers with external unpackers, Cartouche SHALL extract the parts through its own unpacker driver without executing setup.tmp or ISDone. Unknown formats SHALL retain the normal installer path or report unsupported extraction clearly. Support SHALL be based on verified recipes, not inferred from a .bin extension. Recipe evidence SHALL be distinguished from completed app integration.

#### Scenario: Verified CarX Street recipe
- **WHEN** the CarX Street test case is extracted with the CLS Init_MapFile_ driver and unarc.dll FreeArcExtract under WineHQ 11.18
- **THEN** the direct recipe exits successfully, all 905 real files pass MD5 verification with zero mismatches, output totals 22,703,585,753 bytes, and CarX Street.exe is present; the malformed wildcard row is reported separately from real files

#### Scenario: No setup wrapper on direct path
- **WHEN** the supported direct-unpack path runs
- **THEN** process evidence shows no setup.tmp or ISDone execution

#### Scenario: Unsupported external-unpacker format
- **WHEN** parts do not match a verified direct-unpack recipe
- **THEN** Cartouche does not claim successful direct support and offers the normal installer path or a clear unsupported-extraction message

