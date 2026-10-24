# Release startup fixes delta

## ADDED Requirements

### Requirement: Verify updates before extraction
The release app SHALL enable SUVerifyUpdateBeforeExtraction in Info.plist so Sparkle starts with the selected verification configuration. ReleaseFeedTests SHALL guard this setting.

#### Scenario: Release configuration
- **WHEN** the release Info.plist is checked
- **THEN** SUVerifyUpdateBeforeExtraction is enabled and the regression test rejects its removal
