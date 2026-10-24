# Approved decision batch delta

## MODIFIED Requirements

### Requirement: Advanced Windows-game options
The Cartouche game panel SHALL expose an Advanced section for all Windows-game sources. Its controls are DLSS→MetalFX, MetalFX upscaling, AVX2 to Rosetta, MSync, High Resolution and Metal HUD, and it SHALL NOT offer frame generation (ADR 0031). Each control SHALL be offered only for a game whose selected runner and graphics backend support it. Runtime mechanisms and per-pair eligibility SHALL be established by research-upscaling before implementation claims or defaults are assigned.

#### Scenario: Windows-game source coverage
- **WHEN** a Windows game from Steam, another store, an installer or an in-place import is selected
- **THEN** its game panel has the same Advanced-section entry point, subject to researched runtime eligibility for each control

#### Scenario: Unsupported runner and backend pair
- **WHEN** a game's selected runner and backend do not support an option
- **THEN** that option is not offered in the game's Advanced section, while it may remain offered for a setup that supports it

#### Scenario: No frame generation
- **WHEN** the Advanced section is shown for any setup
- **THEN** it contains no frame-generation control

#### Scenario: Unresearched option
- **WHEN** an option’s runtime mechanism or eligibility has not been confirmed
- **THEN** no working implementation or universal support is claimed for that option
