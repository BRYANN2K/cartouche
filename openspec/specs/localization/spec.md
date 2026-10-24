# localization Specification

## Purpose
English and French app text with consistent platform terminology. French implementation and glossary work are owned by l10n-fr.

## Requirements

### Requirement: French language and glossary
The app SHALL add French alongside English. French copy SHALL use vouvoiement, Apple’s macOS terminology and the glossary maintained by l10n-fr at docs/l10n/glossary-fr.md. The glossary SHALL be created and reviewed before French localization is marked complete.

#### Scenario: French interface copy
- **WHEN** app copy is reviewed in French
- **THEN** it uses vouvoiement and consistent glossary terms aligned with Apple macOS terminology

#### Scenario: Glossary ownership
- **WHEN** French terminology is added or changed
- **THEN** l10n-fr records the chosen terms in docs/l10n/glossary-fr.md and localization is not marked complete merely because a glossary path was planned
