# Release-app startup and process-probe fixes

Status: implemented in main f9bb3d7, including Sparkle fix 8b6b29b.

## Changes

Move blocking process waits out of SwiftUI view/menu updates and keep GameMenu.items pure with cached busy state. Run uninstall planning/probes detached and confirm on the main actor. Enable SUVerifyUpdateBeforeExtraction so Sparkle starts; ReleaseFeedTests guards the setting.

These are fixed issues, not unresolved known issues. A documentation update is not a fresh release smoke test.
