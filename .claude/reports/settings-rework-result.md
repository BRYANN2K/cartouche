# Settings rework

Implementation in phase/settings-rework, worktree sol-settings-rework.

- Glass-style sidebar Settings with Steam and Wine Prefixes; Compatibility displays as Runners while its persisted raw value remains unchanged.
- Removed Setup and Prefix menus, number shortcuts, and separate Steam Play Setup scene.
- Steam reuses existing status actions and confirmations: location, integration, client updates, controller reset, components, maintenance, advanced diagnostics.
- Removed CrossOver.app requirement UI; optional detection/runner logic unchanged.
- Wine Prefixes preserves per-game table, Wine tools, size, runner, backups, rebuild/delete; visible inline selection actions.
- Backup restore copies to staging, retains the selected backup, parks current prefix as another backup, validates paths/ownership, respects launch claims, rolls back on failure, drops stale build attribution.
- One prioritized integration issue banner in library and Steam Settings. Routes to Steam or Runners.
- Help > Troubleshooting contains refresh/log actions.

Assumptions: preserve all existing registration and install operation semantics. Optional CrossOver discovery remains supported by existing runner code. No constants changed; Settings uses 900×640 layout and 184-point sidebar. Existing backup discovery is unchanged (backups without a current prefix are not listed).

Validation pending.
