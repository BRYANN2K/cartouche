# Cartouche privacy

What Cartouche asks macOS for, what it sends over the network, and what stays on your Mac. Read by users, contributors and reviewers. The rules come from `openspec/specs/mac-permissions/` and `openspec/specs/compatibility-data/`, and from the code.

Cartouche has no server and no account. It does not collect analytics. Every request below goes to a service run by someone else.

## What is built and what is planned

- The permissions module, the MacGamingDB client, the compatibility file client, Sparkle updates and the RetroArch core downloads are merged.
- The screens that start some permission requests come with later phases (Settings window P5, installer P6, downloads P7, consoles P13, netplay P14, controls P15, onboarding P18). Until then the module is complete but the running app does not yet reach every request. The table below says which phase asks for each permission.
- FPS tracking (P8) is not merged. Nothing measures frame rates today.

## macOS permissions

Cartouche asks for a permission only when you start the feature that needs it. It shows one sentence about why, then the macOS prompt. It never asks at launch. It never asks for a permission no feature uses.

| Permission | Whose grant | Feature | When it is asked | If you say no |
|---|---|---|---|---|
| App Management | Cartouche | Adds Steam Play to the Steam app | Onboarding, Steam step. macOS has no prompt for it: it blocks the first write to Steam.app and notifies you | The Steam step says why and offers Open System Settings. The rest of onboarding goes on |
| Accessibility | Steam | Controllers in Steam games (Steam Input) | First Steam launch through Cartouche | Steam Input is off. Steam games still run |
| Accessibility | Cartouche | Controller for keyboard-only games (P15) | The first time you turn the option on | The option turns back off and says why |
| Input Monitoring | Windows games | Keyboard in some games | Only if a game needs it. The game's error shows the fix | The keyboard may fail in that game |
| Input Monitoring | Cartouche | Remap the Mac keyboard and mouse per game (P15) | The first time you turn remapping on | Remapping stays off. It applies only after a relaunch, see below |
| Downloads folder | Cartouche | Suggest installers that appear in Downloads (P6) | When you turn the option on. Onboarding can also offer it | The option turns back off with "Cartouche can't read Downloads. Allow it in System Settings." Drag and drop still works |
| Removable Volumes | Cartouche | Game folders on an external disk (P13) | When you add such a folder | The folder is marked unavailable |
| Local Network | Cartouche | Netplay and LAN games (P14) | The first netplay or LAN game | Internet netplay still works |
| Notifications | Cartouche | Download finished, install finished, ready to play (P7) | Once, after the first download or install finishes. Never at launch | No banners. The activity slot still shows progress |
| Login Items | Cartouche | Open Cartouche at login | When you turn the option on | It stays off |
| Keychain | Cartouche | Store sign-ins for Epic, GOG, Amazon and RetroAchievements (P10, P14) | Never prompts. The signing identity is stable | Not applicable |

Cartouche reads and asks only for its own grants. It cannot read Steam's or a game's grant, so Settings > Privacy shows "Unknown, will be asked when needed" for those.

### Not requested

- Full Disk Access.
- Screen Recording.
- Camera.
- Microphone.
- Bluetooth. Controllers pair through macOS.

The app's Info.plist has exactly three usage descriptions: Downloads folder, Removable Volumes and Local Network. A test fails if a usage description or a camera, microphone, screen capture or Bluetooth API appears.

### Onboarding

Onboarding asks only for App Management and the Downloads folder. Neither needs a relaunch. Onboarding never asks Cartouche to quit.

### Settings > Privacy

- It lists every permission above with its feature and its state: Allowed, Not allowed, Not asked yet, or Unknown, will be asked when needed.
- Open System Settings goes to the exact pane. If the pane link fails, it falls back to Privacy & Security, then to System Settings.
- After you allow a permission in System Settings and switch back, the state updates without restarting Cartouche.
- The same page holds the MacGamingDB toggle, see below.

### Relaunch

macOS applies Input Monitoring to a running app only after the app restarts. For this permission only:

- Cartouche says so before the macOS prompt.
- If you choose Later in the macOS alert, the Controls screen shows "Relaunch Cartouche to finish" with a Relaunch button. The option shows "Waiting for a relaunch". The rest of Cartouche keeps working.
- Cartouche never relaunches while a game it started is running. It waits for the game to exit, says so in a banner, and you can cancel.
- It saves the screen you were on and reopens there. Saved screens older than 15 minutes are ignored.
- If App Management looks allowed but the Steam step still gets a write refusal, the step offers Relaunch Cartouche. Onboarding then reopens on the PC games step.

Cartouche counts a game as running when a process runs from one of its runner clones. Console games (P12) need their own check, which is not written yet.

### Updates keep grants

Every release is signed with the same self-signed certificate, so macOS keeps your grants after a Sparkle update. If the certificate is ever replaced, macOS asks again. The release notes will say so. See `docs/RELEASE.md`.

Not yet measured: the update test on two signed builds and the table of which permissions apply without a relaunch on macOS 15, 26 and 27. The P17 evidence lists them as manual checks.

## What leaves your Mac

Cartouche sends no account, no Mac serial number and no list of your library. These are all the destinations in the code.

| Destination | When | What the service can see | Can you turn it off |
|---|---|---|---|
| macgamingdb.app | When you open a game's details or the estimate needs it, if the toggle is on | The Steam App ID of that game, your IP address, and the User-Agent `Cartouche/<version>` with the project website | Yes: Settings > Privacy > Fetch Mac reports from MacGamingDB |
| github.com release asset `compat-data` | At most once a day | A plain download request: your IP address and the User-Agent `Cartouche/<version>` | No setting exists today |
| github.com `appcast.xml` (Sparkle) | The daily update check | A plain download request. The Info.plist does not turn on Sparkle's system profile | Not decided. Beta releases are a separate opt-in |
| buildbot.libretro.com | When you add a console (its core and the core info archive), or when you pick an official RetroArch release | A plain download request | Cores download only for consoles you add |
| raw.githubusercontent.com | When you install a redistributable with Winetricks | A plain download request for the pinned Winetricks script | You choose to run it |
| Steam content servers (`steamstatic.com`, `steamcdn-a.akamaihd.net`, `media.steampowered.com`) | When Cartouche installs its Steam integration or fetches a Steam game's icon | A plain download request. Packages are checked against pinned SHA-256 values | Inherited from NotProton |

### MacGamingDB

- The request is `GET https://macgamingdb.app/api/rest/games/<Steam App ID>`.
- MacGamingDB can see which games you open, with your IP address. Cartouche sends no account and no Mac identifier beyond the HTTP request.
- Cartouche asks for one game at a time, only for the game you opened. It never asks for your whole library.
- It asks again for the same game at most once a day, and at most two requests run at once.
- With the toggle off, no request goes to macgamingdb.app. The panel shows AppleGamingWiki data and no estimate, and says Mac reports are turned off.
- The toggle is on by default.
- MacGamingDB publishes no data license. Cartouche reads its reports live and keeps them on your Mac. It does not copy them into the nightly file or anywhere else.

### The nightly compatibility file

- CI builds it from AppleGamingWiki, ProtonDB and AreWeAntiCheatYet. It holds no MacGamingDB data and nothing about you.
- The app downloads it at most once a day and keeps the last valid copy. A failed connection does not count as the day's download.
- A file that fails schema validation, or that is older than the copy in use, is discarded.

### Sparkle updates

- Sparkle fetches the signed `appcast.xml` from Cartouche's GitHub releases. The app accepts only updates signed with Cartouche's EdDSA key.
- Sparkle's own check interval is one day. The release specification requires an update to be offered within 24 hours.

### RetroArch cores

- Cores are never bundled. Cartouche downloads a core from the libretro buildbot (`nightly/apple/osx/arm64/latest/`) for each console you add, and takes only the named file out of the archive.
- It records the size and SHA-256 when it first downloads a core, and checks them again at each launch.
- Your games, saves and BIOS files are never uploaded.
- Cartouche never links to a BIOS or game download.
- RetroArch itself starts with Cartouche's own configuration. It does not read or write your own `retroarch.cfg`. Netplay and RetroAchievements (P14) are not merged.

## What stays on your Mac

- Your library, favorites, game setups and settings.
- The compatibility file and the per-game MacGamingDB answers (`~/Library/Application Support/Cartouche/compatibility/`).
- Frame rates (P8). When P8 lands, sessions are stored in a local SQLite file in the Cartouche folder. Nothing is sent unless you turn on sharing, which is a separate opt-in. The spec for sharing is not final, so which fields would be sent is Not decided.
- Logs in `~/Library/Logs/Cartouche`.
- Epic, GOG and Amazon tokens go to the macOS Keychain only (P10, not merged).

## Not decided

- A setting to turn off the daily update check and the daily download of the compatibility file.
- The fields of opt-in FPS sharing with MacGamingDB (P8).
- Which permissions need a relaunch beyond Input Monitoring. The P17 matrix is unmeasured.
