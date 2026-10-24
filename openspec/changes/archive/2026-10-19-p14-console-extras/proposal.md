# Proposal

## Why

Beyond playing, RetroArch already offers what makes console games social and approachable: online play, achievements, translation of Japanese games. Cartouche should make them one click away, and add an opt-in coach built on RetroArch's MCP tools.

## What Changes

- Netplay: host from the game panel, join from a list of friends' games in RetroArch's lobby.
- RetroAchievements: sign in once, show unlocked and remaining achievements, Hardcore mode.
- Screen translation through RetroArch's AI service, with a translation service the user sets up.
- Save states and saves in iCloud Drive.
- Coach mode (experimental): an agent reads named game values through RetroArch's MCP tools and helps when asked.
- Non-goals: hosting our own netplay relay or translation server.
- Depends on P13.

## Capabilities

### New Capabilities
- `console-extras`: online play, achievements, translation, cloud saves and the coach for console games.

### Modified Capabilities
- None.

## Impact

RetroAchievements web API client (user API key in the Keychain), netplay settings in Cartouche's appended config, iCloud Drive paths, Coach mode wiring with P11's MCP server.
