# Approved decision batch delta

## MODIFIED Requirements

### Requirement: Static classification with evidence and confidence
Detection SHALL use static inspection only (filenames, sizes, magic, PE structure and overlay, archive parser results, sidecars, volume families) and SHALL report evidence and a confidence level for every classification (ADR 0028). Ambiguous or conflicting evidence SHALL be shown to the user; an unknown executable SHALL NOT run by default.

#### Scenario: Inno beyond the supported range
- **WHEN** innoextract reports an Inno data version beyond its recorded supported range (innoextract 1.9: Inno 1.2.10–6.2.2)
- **THEN** the input is classified as Inno-like and unsupported, not as a generic archive

#### Scenario: Runtime decompressor helpers
- **WHEN** an Inno installer references helpers such as ISDone.dll, unarc.dll or CLS-*.dll
- **THEN** it is classified as an installer requiring runtime behavior and is not claimed reproducible by static extraction alone

#### Scenario: Incomplete archive set
- **WHEN** a multi-volume archive set is missing a required volume
- **THEN** the missing volume is named and extraction is blocked

#### Scenario: Portable build
- **WHEN** extracted contents match an installed-game layout
- **THEN** the input is classified as a portable build and no redistributable is run automatically

#### Scenario: Conflicting evidence
- **WHEN** markers disagree about an input's type
- **THEN** the observed facts and confidence are presented and the user decides

#### Scenario: Unknown executable
- **WHEN** an executable matches no known format
- **THEN** it is not run by default
