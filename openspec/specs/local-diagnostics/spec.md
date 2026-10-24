# local-diagnostics Specification

## Purpose
Diagnose crashes with local reports and user-controlled copying. Implementation is pending; ADR 0029 applies.

## Requirements

### Requirement: Local crash reports and diagnostics
Crash reports SHALL remain local with no network reporting. The next launch after a crash SHALL offer Show Report and Copy Summary. Collect Diagnostics SHALL create a local zip of logs and reports. The user MAY share these manually; neither command SHALL upload data.

#### Scenario: Copy crash summary
- **WHEN** the user chooses Copy Summary after a crash
- **THEN** a summary is copied for the user to paste, with no network request

#### Scenario: Collect diagnostics
- **WHEN** the user chooses Collect Diagnostics
- **THEN** a diagnostics zip is created locally and nothing is sent over the network
