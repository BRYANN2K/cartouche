# Cartouche privacy

What Cartouche asks macOS for, what it sends over the network, and what stays on your Mac. Read by users, contributors and reviewers. The rules come from `openspec/specs/mac-permissions/` and `openspec/specs/compatibility-data/`, and from the code.

Cartouche v0.1.0 has no server and no account. It does not collect analytics. Every request below goes to a service run by someone else. Opt-in statistics sharing and a public game list with user stars at cartouche.bryann2k.dev are planned for v0.1.1. No submission service or final field list is approved yet; update this page before enabling either feature.

## What is built and what is planned

- Agent control (P11) is merged. It exposes local tools to the MCP clients you authorize. Clients may send tool results to their own services; review the client’s policy. Cartouche itself sends no agent data to a Cartouche server.
- Ranked identification, privacy-gated Steam search, PE-based runtime steps, managed-game uninstall and closed-Steam cache handling are merged. The archive backend and its app adapter are merged. Direct unpack is merged, with a fallback to the original setup on Try Again; app end-to-end checks remain pending.
- FPS tracking (P8) is merged: sessions are measured and stored locally. Sharing them with MacGamingDB is coded but has no destination: MacGamingDB publishes no way to send reports. The sharing UI is hidden in v0.1.0 and comes back as an opt-in in v0.1.1 (see `docs/ROADMAP.md`). Nothing is sent.
- Store sign-ins (P10), netplay, RetroAchievements, the translation service and iCloud Drive saves (P14) are merged and described below.

## macOS permissions

Cartouche asks for a permission only when you start the feature that needs it. It shows one sentence about why, then the macOS prompt. It never asks at launch. It never asks for a permission no feature uses.

| Permission | Whose grant | Feature | When it is asked | If you say no |
|---|---|---|---|---|
| App Management | Cartouche | Adds Steam Play to the Steam app | Onboarding, Steam step. macOS has no prompt for it: it blocks the first write to Steam.app and notifies you | The Steam step says why and offers Open System Settings. The rest of onboarding goes on |
| Accessibility | Steam | Controllers in Steam games (Steam Input) | First Steam launch through Cartouche | Steam Input is off. Steam games still run |
| Accessibility | Cartouche | Controller for keyboard-only games (P15) | The first time you turn the option on | The option turns back off and says why |
| Input Monitoring | Windows games | Keyboard in some games | Only if a game needs it. The game's error shows the fix | The keyboard may fail in that game |
| Input Monitoring | Cartouche | Remap the Mac keyboard and mouse per game (P15) | The first time you turn remapping on | Remapping stays off. It applies only after a relaunch, see below |
| Downloads folder | Cartouche | Suggest installers that appear in Downloads (P6) | When you turn the option on | The option turns back off with "Cartouche can't read Downloads. Allow it in System Settings." Drag and drop still works |
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

Onboarding asks only for App Management, in the PC games step, before it modifies Steam. It needs no relaunch. Onboarding never asks Cartouche to quit.

The Folders and privacy step holds toggles, not macOS permissions: which game folders to use, and the MacGamingDB toggle. The Downloads folder, FPS sharing and other permissions are not in onboarding.

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
| store.steampowered.com | When a Windows installer game has no Steam app ID for its cover, and when you use Change Cover > Search Steam; only if the toggle is on | The game's name in a search request, your IP address, and the User-Agent `Cartouche/<version>` | Yes: Settings > Privacy > Fetch Mac reports from MacGamingDB |
| The Cartouche community site (`CartoucheCommunityURL`; unset in builds until the service is live) | Reading: the app feed at most once an hour once its refresh time has passed, if the Mac reports toggle is on; the fix registry and a fix when you open Review on a shared fix. Sending: only what you confirmed in Share My Results or Share a Fix, and the status of your own contributions in My Contributions | Your IP address and `Cartouche/<version>`. With a contribution: the game's store ID, the report or fix you previewed, and your pseudonymous contributor key. No account, Steam ID, Mac serial, path or log | Reading: Settings > Privacy > Fetch Mac reports. Sending happens only when you press Share; drafts and unsent items can be deleted from My Contributions |
| github.com release assets: `compat-data` (the compatibility file) and `BRYANN2K/cartouche-wine` `manifest` (the signed runner manifest) | At most once a day | A plain download request: your IP address and the User-Agent `Cartouche/<version>` | Yes: Settings > General > Check for updates and compatibility data daily |
| github.com `appcast.xml` (Sparkle) | The daily update check | A plain download request. The Info.plist does not turn on Sparkle's system profile | Yes: the same switch pauses the automatic check. Check for Updates in the Cartouche menu always works. Beta releases are a separate opt-in |
| buildbot.libretro.com | When you add a console (its core and the core info archive), or when you pick an official RetroArch release | A plain download request | Cores download only for consoles you add |
| raw.githubusercontent.com | When you install a redistributable with Winetricks | A plain download request for the pinned Winetricks script | You choose to run it |
| Steam content servers (`steamstatic.com`, `steamcdn-a.akamaihd.net`, `media.steampowered.com`) | When Cartouche installs its Steam integration, fetches a Steam game's icon, or downloads a game's cover art | A plain download request. Packages are checked against pinned SHA-256 values | Inherited from NotProton |
| github.com release assets of the store clients | The first time each store needs its client | A plain download request for a pinned release asset, checked by size and SHA-256 | Clients download only for stores you sign in to |
| epicgames.com | Epic sign-in, and everything legendary does: listing your games, downloads, cloud saves | Epic's page sees the account you sign in with. legendary sends it your tokens and the game IDs you install or play | You sign in per store. Sign out deletes the tokens |
| auth.gog.com, embed.gog.com, remote-config.gog.com, gamesdb.gog.com | GOG sign-in; the library list, cloud-save locations and covers read by Cartouche itself with your token; everything gogdl does (downloads, save sync); comet beside a running GOG game | The account you sign in with. comet answers the game's Galaxy calls with your tokens | You sign in per store. Sign out deletes the tokens |
| amazon.com | Amazon sign-in, and everything nile does: registering as a device, listing your games, downloads | Amazon's page sees the account you sign in with. nile sends it your tokens and the game IDs you install or play | You sign in per store. Sign out deletes the tokens |
| retroachievements.org | Sign-in once, then achievement lookups for console games you open | Your username, the password once over HTTPS (never stored), then the token; the hash of a game file and the counts of games you played | Settings > Consoles > Sign Out deletes the token. Achievements are off until you sign in |
| lobby.libretro.com and libretro's MITM relay | When you open Join, or host a console game with the lobby | Join: a plain HTTP request for the room list. Host: your nickname, the game's name and checksum, the core, and the address to reach you; the session may run through the relay | Host without the lobby is not offered today. Local-network rooms need no lobby |
| The translation service you configured | When you ask to translate the screen in a console game | RetroArch sends the current frame to that service. You choose the service; Cartouche only writes its address into RetroArch's settings | The option does nothing until you set a service |
| iCloud Drive (Apple) | While "Save states to iCloud Drive" is on | Your console save files and save states, synced by macOS like any iCloud Drive folder | Turning the option off copies the files back to the Mac |

### Game identification and local files

Ranked local identification and the Steam store fallback are merged. Local evidence includes store IDs, installer titles where available, engine metadata, PE version information, executable names and folder names. The shared Steam lookup path is controlled by Settings > Privacy > Fetch Mac reports from MacGamingDB. This existing toggle gates both Mac reports and Steam name searches; its wording does not mean Steam search has a separate switch. See The Steam store search below for request fields and cache details.

PE-based runtime detection reads local executable imports. Wine Mono covers .NET; required winetricks steps run one at a time with timeout and Skip. No game files are uploaded by that analysis.

Managed-game uninstall is merged: the game and prefix move to the Trash, with Keep save files offered for save folders found in the prefix. Removing an in-place import moves only Cartouche’s prefix and record to the Trash; the external source files stay untouched. Save copies stay locally under Cartouche’s saves folder.

Archive decompression and direct extraction of supported installers run locally and do not upload game files. The archive backend and its app adapter are merged. Direct unpack and its Try Again fallback are merged; end-to-end app verification is pending.

### The Cartouche community site

- Nothing is shared automatically. A result or a fix leaves the Mac only after you confirmed its preview. The automatic frame-rate sharing path stays off and has no destination.
- Statistics and hardware (chip, memory, macOS version, model, CPU cores, FPS, resolution) are sent only when "Share statistics and this Mac's hardware" is on for that report. Without it, the report carries the game, the method, the runner and backend, your answers and your comment.
- The first share creates a pseudonymous contributor key on the site. It is kept in the macOS Keychain (`dev.bryann2k.cartouche.community`), is not linked to an account or to the Mac, and lets you edit or withdraw what you shared.
- Confirmed contributions wait in `community/queue.json` while the site is unreachable. They are never sent to MacGamingDB or another service.
- Contributions are published under CC0 1.0 only after a moderator approves them. A withdrawn report is removed from the site's aggregates; copies already downloaded by others cannot be recalled.
- Shared fixes are applied only after their signature, list of valid fixes, expiry and revocations check out. Your previous setup is saved in `community/applied-fixes.json` so Undo Fix restores it.

### MacGamingDB

- The request is `GET https://macgamingdb.app/api/rest/games/<Steam App ID>`.
- MacGamingDB can see which games you open, with your IP address. Cartouche sends no account and no Mac identifier beyond the HTTP request.
- Cartouche asks for one game at a time, only for the game you opened. It never asks for your whole library.
- It asks again for the same game at most once a day, and at most two requests run at once.
- With the toggle off, no request goes to macgamingdb.app. The panel shows AppleGamingWiki data and no estimate, and says Mac reports are turned off.
- The toggle is on by default.
- MacGamingDB publishes no data license. Cartouche reads its reports live and keeps them on your Mac. It does not copy them into the nightly file or anywhere else.

### The Steam store search

- The request is `GET https://store.steampowered.com/api/storesearch/?term=<game name>&l=english&cc=US`. It is Steam's public store search: no key and no account.
- Steam can see the game's name, with your IP address. No account and no Mac identifier is sent.
- Automatic search runs only when local identification leaves no known Steam App ID; Change Cover > Search Steam is a user-requested search through the same path. Cache entries reduce repeat requests: a found app ID is kept on the game's install record, and the search answers are cached in `compatibility/steam-lookup/` (a found answer for a month, a no-match for a day, an unreachable Steam for an hour).
- Change Cover > Search Steam shows the same search's results; picking one downloads that game's cover from Steam's content servers. Cover art itself is a plain image download and carries no name.
- With the toggle off, no search goes to steampowered.com and the picker says Steam lookups are turned off.

### The nightly compatibility file

- CI builds it from AppleGamingWiki, ProtonDB and AreWeAntiCheatYet. It holds no MacGamingDB data and nothing about you.
- The app downloads it at most once a day and keeps the last valid copy. A failed connection does not count as the day's download.
- A file that fails schema validation, or that is older than the copy in use, is discarded.
- The runner manifest comes from the `manifest` release of the public `BRYANN2K/cartouche-wine` repository. The app trusts it only when its `runners.json.sig` signature verifies against the EdDSA public key the app ships (`SUPublicEDKey`); otherwise the bundled manifest stays in use.
- Settings > General > Check for updates and compatibility data daily pauses both downloads when it is off. The switch is on by default.

### Sparkle updates

- Sparkle fetches the signed `appcast.xml` from Cartouche's GitHub releases. The app accepts only updates signed with Cartouche's EdDSA key.
- Sparkle's own check interval is one day. The release specification requires an update to be offered within 24 hours.
- The same daily switch pauses Sparkle's automatic check. Check for Updates in the Cartouche menu is not affected.

### RetroArch cores

- Cores are never bundled. Cartouche downloads a core from the libretro buildbot (`nightly/apple/osx/arm64/latest/`) for each console you add, and takes only the named file out of the archive.
- It records the size and SHA-256 when it first downloads a core, and checks them again at each launch.
- Your games, saves and BIOS files are never uploaded.
- Cartouche never links to a BIOS or game download.
- RetroArch itself starts with Cartouche's own configuration. It does not read or write your own `retroarch.cfg`.

### Console extras (P14)

- Netplay is RetroArch's own. Cartouche starts it with RetroArch's host and connect flags. Hosting announces the game to libretro's lobby under your netplay nickname and plays through libretro's MITM relay. Joining reads the lobby's room list and, with Local Network allowed, the games on your network (Bonjour `_ra_netplay._tcp`). Cartouche runs no lobby or relay of its own.
- The netplay nickname is the name you choose, else your RetroAchievements name, else RetroArch's default. It is never your Mac's account name.
- RetroAchievements sign-in sends your password once to retroachievements.org over HTTPS. The answer's token is the only thing kept, in the Keychain. Cartouche then asks the site for game IDs (from a hash of your game file, the way rcheevos computes it) and your unlock counts. RetroArch gets the token while it starts, and it is removed from the written configuration right after.
- Hardcore mode is enforced by RetroArch: save states and rewind are off, and Cartouche refuses input tools to a Hardcore session.
- The translation service is an address you set in Settings > Consoles. RetroArch's AI service sends the frame to it only when you ask for a translation.
- With "Save states to iCloud Drive" on, Cartouche's `saves` and `states` folders become links to `iCloud Drive/Cartouche/Saves` and `…/States`. The newer copy wins when they merge, and turning the option off copies everything back. Sync is Apple's own iCloud Drive; Cartouche has no cloud.
- Coach mode reads named values of a running game through Cartouche's own relay. It sends nothing to a server.

### Steam owned-library export (merged; real Steam check pending)

The full owned-games list comes from Steam’s signed-in client, through a WebUI route registered by Cartouche’s injected dylib. Only Cartouche’s injected page script receives the random token for that Steam launch. The dylib validates the request and atomically writes SteamExport v1 `steam-library.json` locally. This adds no loopback HTTP service and requires neither a public Steam profile nor a user Web API key. The export stays on your Mac; this feature does not upload your library to Cartouche.

When Steam is closed, Cartouche uses the last account-matched export even if stale and labels it cached/stale. Installed status comes from appmanifests. localconfig.vdf is play data only, not ownership. Implementation is merged. It polls every 15 seconds and sends only changes, validates payloads up to 4 MB, writes mode 0600 and refuses symlinks. Real Steam verification remains pending; see ADR 0022.

## What stays on your Mac

- Your library, favorites, game setups and settings.
- The cached Steam library export (`steam-library.json`), console games, store library lists and install records (`stores/`).
- The compatibility file, the per-game MacGamingDB answers and the Steam name-lookup answers (`~/Library/Application Support/Cartouche/compatibility/`).
- The community feed, your contribution queue and the setups saved before a shared fix (`~/Library/Application Support/Cartouche/community/`).
- Frame rates: one SQLite file, `performance/sessions.sqlite`, in the Cartouche folder (P8). Nothing is sent; v0.1.0 shows no sharing control, and MacGamingDB has no way to receive reports. If one ever existed, a report would carry only the chip, memory, macOS version, runner, backend, filtered settings and the FPS.
- Logs in `~/Library/Logs/Cartouche`.
- Planned local crash reports and diagnostics bundles (ADR 0029; implementation pending): after a crash, the next launch offers Show Report and Copy Summary; Collect Diagnostics creates a local zip. Nothing is sent over the network. Users choose whether to share files themselves.
- Epic, GOG and Amazon tokens, and the RetroAchievements token, in the macOS Keychain only. Details below.
- Console extras (`retroarch/extras.json`): RetroAchievements username, the translation service address, the netplay nickname, per-game toggles and the last achievement counts. No secrets in it.

### Store sign-ins (P10)

- Sign-in happens on each store's own page: epicgames.com for Epic, auth.gog.com for GOG, the Amazon page nile prepares for Amazon. Cartouche never renders a password field; it only reads the one-time code the page hands over.
- Each store keeps one item in the Keychain, a generic password under Cartouche's own service, readable only while the Mac is unlocked and never synced to other devices.
- The clients keep their tokens in files. Cartouche writes those files into the client's own folder just before it runs, collects them back into the Keychain when it ends, and deletes them. Files a crash leaves behind go back into the Keychain at the next start. No file under `stores/` keeps a token.
- Each client runs with its own HOME, temporary folder and a minimal environment. It talks only to its store: legendary to Epic's servers, gogdl to GOG, nile to Amazon. comet runs beside a GOG game and answers the game's Galaxy calls (achievements and friends) with your tokens. Cartouche itself calls GOG's web API with your bearer token for the library, save locations and covers.
- Sign out deletes the Keychain item and asks the client to forget.

## Not decided

- Which permissions need a relaunch beyond Input Monitoring. The P17 matrix is unmeasured.
- A netplay host that skips libretro's lobby. Hosting always announces today.
