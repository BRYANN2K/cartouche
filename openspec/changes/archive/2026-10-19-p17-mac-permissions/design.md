# Design

## Context

Cartouche is not sandboxed (it modifies Steam), so TCC still guards: App Management (modifying other apps, macOS 13+), Accessibility and event posting, Input Monitoring, Files and Folders (Downloads, Documents, Desktop, removable volumes), Local Network (macOS 15), Notifications, Login Items. NotProton already detects App Management refusals and asks Steam's event access.

## Inventory

| Permission | Who needs it | Feature | When it is asked | If denied |
|---|---|---|---|---|
| App Management | Cartouche | Install the Steam integration (modify Steam.app) | Onboarding, step "Steam" | Steam Play features off; banner with Open System Settings |
| Post events / Accessibility | Steam | Steam Input (controller in Steam games) | First Steam launch through Cartouche (NotProton behavior) | Steam Input off; Steam games still run |
| Accessibility | Cartouche | Controller for keyboard-only games (P15) | First time the option is turned on | Option stays off with the reason |
| Input Monitoring | Wine game processes | Keyboard read by SDL in some games | Only if a game needs it; shown in the game's error | Game keyboard may fail; fix shown |
| Input Monitoring | Cartouche | Remap Mac keyboard and mouse per game (P15) | First time remapping is turned on in Controls; applies after a relaunch | Remapping off; Left ⌘ as Ctrl (Wine setting) still works |
| Files and Folders: Downloads | Cartouche | Suggest installers in Downloads (P6) | When the option is turned on | Option off; drag and drop still works |
| Files and Folders: Removable Volumes | Cartouche | Game folders on an external disk (P13) | When the user adds such a folder | Folder marked unavailable |
| Local Network | Cartouche and Wine games | Netplay on the LAN (P14), LAN games | First netplay host or LAN game | Internet netplay still works |
| Notifications | Cartouche | Download, install, ready to play (P7) | After the first download or install, not at launch | No banners; activity slot still shows progress |
| Login Items | Cartouche | Open at login (Settings > General) | When the user turns it on | Stays off |
| Keychain | Cartouche | Store tokens (Epic, GOG, Amazon, RetroAchievements) | Implicit, no prompt with a stable signature | – |

Not requested: Full Disk Access, Screen Recording, Camera, Microphone, Bluetooth (controllers pair through macOS).

## Decisions

- **Just in time, with a Cartouche sheet first.** One sentence on why, one button that triggers the macOS prompt. Rejected: asking everything in onboarding (users deny in bulk), and asking with no explanation.
- **Onboarding asks only App Management**, because Steam integration is the first thing users want and it fails without it. Everything else waits for its feature.
- **Relaunch is Cartouche's job.** Only Input Monitoring needs one (macOS shows "Quit & Reopen"). The explanation says it first; on Later, Cartouche shows its own Relaunch button. Relaunch waits for running games, saves the current screen, starts a new instance (`open -n` on its own bundle after exit) and restores the screen. To confirm on macOS 15, 26 and 27: which permissions apply live (App Management, Accessibility, Files) and which need the relaunch.
- **Deep links** to the exact System Settings pane (`x-apple.systempreferences:com.apple.preference.security?Privacy_...`) for recovery.
- **Stable self-signed identity (P9)** so grants survive updates. Rejected: ad hoc signing, which resets grants at every release.

## Risks / Trade-offs

- [Pane URLs change between macOS versions] → tested on 15 and 26; fallback opens Privacy & Security root.
- [Some states cannot be read without prompting] → show "Unknown, will be asked when needed" instead of guessing.
