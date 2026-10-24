# P7 research: Steam downloads and activity on macOS

Date of research: 2026-10-19. Search tool was weak on primary sources, so several items are "Unconfirmed".
Local checks were read-only, on a Mac with Steam client version 1791918634 and no games installed (so no manifest or download samples).

## Question

Facts for Cartouche P7 (downloads and activity): appmanifest keys and StateFlags, content_log formats, SteamClient JS download API, steam:// URLs, running-app signal on macOS, and the steamloopback.host server.

## Short answer

- StateFlags bit names are known (Q1), the JS API has Pause/Resume/Remove/Queue but one source says PauseAppUpdate may be broken (Q3).
- Real content_log lines are confirmed for queued, started, changed, canceled, finished-with-result (Q2); the exact "paused by user" line is not confirmed.
- RunningAppID is probably not usable (Linux issue: always 0); steamloopback.host serving extra files in steamui is plausible but unconfirmed (Q5, Q6).

## Q1. appmanifest keys and StateFlags

**StateFlags bit names**
- Confirmed (2015 table, flagged older than 12 months, "may be outdated"): 1 Uninstalled, 2 UpdateRequired, 4 FullyInstalled, 8 Encrypted, 16 Locked, 32 FilesMissing, 64 AppRunning, 128 FilesCorrupt, 256 UpdateRunning, 512 UpdatePaused, 1024 UpdateStarted, 2048 Uninstalling, 4096 BackupRunning, 65536 Reconfiguring, 131072 Validating, 262144 AddingFiles, 524288 Preallocating, 1048576 Downloading, 2097152 Staging, 4194304 Committing, 8388608 UpdateStopping. Source: [LinuxGSM-Docs errors.md](https://github.com/GameServerManagers/LinuxGSM-Docs/blob/master/steamcmd/errors.md). That page lists 512 as "UpdateRunning" a second time (typo); the name UpdatePaused for 512 comes from Lutris below.
- Confirmed for the low bits (1 to 1024, incl. 512 = Update Paused): [Lutris appmanifest.py](https://raw.githubusercontent.com/lutris/lutris/master/lutris/util/steam/appmanifest.py).
- Conflict: Lutris' list has no bits 8192 to 32768, so its upper names (Reconfiguring 8192 ... UpdateStopping 1048576) are shifted compared with LinuxGSM (65536 ... 8388608). Prefer the LinuxGSM values for bits above 4096. Unconfirmed against a live manifest; verify during a real download.
- Values combine: 1026 = UpdateRequired + UpdateStarted ("update required and previously started"), per [pinkwah/steam-appmanifest README](https://github.com/pinkwah/steam-appmanifest/blob/master/README.md). Installed idle game = 4 ([sample manifest, Steam forum](https://steamcommunity.com/discussions/forum/0/3004430047197048765)).
- The log line `state changed : Update Required,Fully Installed,Files Missing,Files Corrupt,Update Started,` shows the same names Steam prints for the bits ([Steam forum 2023+](https://steamcommunity.com/discussions/forum/1/3183485686841141213/?ctp=3)).

**Keys that change during a download**
- Unconfirmed as a documented list. Keys seen in sample manifests: StateFlags, UpdateResult, BytesToDownload, BytesDownloaded, BytesToStage, BytesStaged, ScheduledAutoUpdate, buildid ([TechFuel HQ 2026](https://techfuelhq.com/gaming/steam-slow-download-speed-2026/), secondary source; and a 2020 forum sample found by search, URL not opened). TargetBuildID: no source found.
- BytesToDownload vs BytesToStage: download is network bytes, stage is bytes written to disk (same TechFuel source, secondary).
- Steam resets values if a user edits them while it runs (Nexus Mods user report, anecdotal).

**Rewrite frequency, paused state, UpdateResult**
- Rewrite frequency: Unconfirmed. No source found. Do not rely on BytesDownloaded for a smooth progress bar until measured on a live download. Prefer the JS API (Q3), which pushes live byte counts.
- Paused in manifest: Unconfirmed. By the bit table, a pause should set 512 (UpdatePaused); verify live.
- UpdateResult values: Probably the EAppUpdateError numbers (see Q3 table: 1 Unspecified, 2 Paused, 3 Canceled, 4 Suspended, 6 NoConnection, 11 DiskWriteFailure, 12 NotEnoughDiskSpace ...). Confirmed that the JS type `DownloadItem.update_result` uses that enum ([Millennium client types](https://app.unpkg.com/@steambrew/client@5.5.0/files/src/globals/steam-client/App.ts)). That the manifest `UpdateResult` key uses the same numbers is Unconfirmed.
- SteamCMD-style hex "state" codes (older, 2015 table): 0x6 no connection to content servers, 0x202 not enough disk quota, 0x212 not enough disk space, 0x402 connection issue, 0x606 disk write failure (permissions), 0x626 missing update files, 0x6A6 corrupt update files. Source: [LinuxGSM-Docs errors.md](https://github.com/GameServerManagers/LinuxGSM-Docs/blob/master/steamcmd/errors.md). Note these are SteamCMD "Error! App state (0x...)" codes, a different encoding than UpdateResult.

## Q2. content_log.txt line formats

Path on this Mac (confirmed locally): `~/Library/Application Support/Steam/logs/content_log.txt`. Lines start with `[YYYY-MM-DD HH:MM:SS] `.

Confirmed real examples, [Steam Client Beta forum, 2024-03-25](https://steamcommunity.com/groups/SteamClientBeta/discussions/0/3775742015034728598/?l=koreana&ctp=3):
- Queued/started state: `AppID 1203620 state changed : Update Required,Update Queued,Update Started,`
- Started: `AppID 1203620 update started : download 150723920/12135331952, store 0/0, reuse 0/0`
- Phase change: `AppID 1203620 update changed : Running Update,Downloading,Staging,`
- Scheduler: `AppID 1203620 scheduler update : Priority Auto Update, not played for 1817 seconds`
- Canceled/suspended: `AppID 1203620 update canceled : Shader Priority (Suspended)`
- Finish with result: `AppID 1203620 scheduler finished : removed from schedule (result Suspended, state 0x40a)`

More confirmed examples:
- Failure with reason: `AppID 916840 update canceled : Failed updating depot 916841 while reading chunk (Device Corrupt) (Corrupt game files)` and `AppID 916840 update started : download 2257773264/2257773264, store 0/0, reuse 8975576679/24420663321,` ([Steam forum](https://steamcommunity.com/discussions/forum/1/3183485686841141213/?ctp=3)).
- Manifest failure, 2018, older than 12 months: `AppID 214490 update canceled : Failed to download manifest ... for depotID 214491 (File Not Found)`, `update changed : Running,Reconfiguring,Stopping,`, `update changed : None`, `state changed : Update Required, (Update delayed for 300 secs)`, `state changed : ...,Update Queued,Update Running,` ([Steam forum](https://steamcommunity.com/discussions/forum/1/1736595227845010961)).
- Success finish: `scheduler finished : removed from schedule` is cited for finish detection; exact "(result Success...)" wording Unconfirmed ([forum summary](https://steamcommunity.com/discussions/forum/1/1736595227845010961), 2018).
- Timeout cancel: `update canceled : Failed updating depot ... while waiting for progress (connection timeout)` and `No servers found for depot` (search summary only, URLs not opened).

Unconfirmed: a line for user-initiated pause (only "Suspended" via shader priority found), and a line for user cancel. Capture these live. The `state 0x40a` in the finish line = 0x400 + 0x8 + 0x2 = UpdateStarted + Encrypted + UpdateRequired by the table above (my derivation, not sourced).

## Q3. SteamClient JS API (Millennium types)

Source: [@steambrew/client 5.5.0 Downloads.ts](https://app.unpkg.com/@steambrew/client@5.5.0/files/src/globals/steam-client/Downloads.ts) and [Downloads docs](https://docs.steambrew.app/plugins/ts/client/src/interfaces/Downloads). Community-typed, not Valve official. Date of version: not shown; Millennium v3.3.0 is dated 2026-06-24 ([release](https://newreleases.io/project/github/SteamClientHomebrew/Millennium/release/v3.3.0)). Confirmed as types only; behavior on macOS not tested here.

`SteamClient.Downloads`:
- `PauseAppUpdate(appId: number): void`. A source comment says "Broken? It seems to be removing it from download list like RemoveFromDownloadList". Treat as Unconfirmed behavior.
- `ResumeAppUpdate(appId: number): void`
- `QueueAppUpdate(appId: number): void`
- `RemoveFromDownloadList(appId: number): void` (moves the update to the unscheduled list)
- `MoveAppUpdateUp(appId)`, `MoveAppUpdateDown(appId)`, `SetQueueIndex(appId, index)` (0 = current download)
- `SetLaunchOnUpdateComplete(appId: number)`
- `EnableAllDownloads(enable: boolean)` (this is the only whole-queue switch in the types; calling it with false is presumably "suspend queue", Unconfirmed)
- `SuspendDownloadThrottling(suspend: boolean)`, `SuspendLanPeerContent(suspend: boolean)`
- `RegisterForDownloadItems(cb: (isDownloading: boolean, items: DownloadItem[]) => void): Unregisterable`
- `RegisterForDownloadOverview(cb: (overview: DownloadOverview) => void): Unregisterable`

`DownloadItem`: active, appid, buildid, completed, completed_time, deferred_time, downloaded_bytes, launch_on_completion, paused, queue_index (-1 if unqueued), target_buildid, total_bytes, update_error (string), update_result (EAppUpdateError), update_type_info (UpdateTypeInfo[]: completed_update, downloaded_bytes, has_update, total_bytes).

`DownloadOverview`: lan_peer_hostname, paused, throttling_suspended, update_appid, update_bytes_downloaded, update_bytes_processed, update_bytes_staged, update_bytes_to_download, update_bytes_to_process, update_bytes_to_stage, update_disc_bytes_per_second, update_network_bytes_per_second, update_peak_network_bytes_per_second, update_seconds_remaining, update_start_time, update_is_install, update_is_prefetch_estimate, update_is_shader, update_is_upload, update_is_workshop, update_state ('None' | 'Starting' | 'Updating' | 'Stopping').

`EAppUpdateError` (from [App.ts](https://app.unpkg.com/@steambrew/client@5.5.0/files/src/globals/steam-client/App.ts)): 0 None, 1 Unspecified, 2 Paused, 3 Canceled, 4 Suspended, 5 NoSubscription, 6 NoConnection, 7 Timeout, 8 MissingKey, 9 MissingConfig, 10 DiskReadFailure, 11 DiskWriteFailure, 12 NotEnoughDiskSpace, 13 CorruptGameFiles, 14 WaitingForNextDisk, 15 InvalidInstallPath, 16 AppRunning, 17 DependencyFailure, 18 NotInstalled, 19 UpdateRequired, 20 Busy, 21 NoDownloadSources, 22 InvalidAppConfig, 23 InvalidDepotConfig, 24 MissingManifest, 25 NotReleased, 26 RegionRestricted, 27 CorruptDepotCache, 28 MissingExecutable, 29 InvalidPlatform, 30 InvalidFileSystem, 31 CorruptUpdateFiles, 32 DownloadDisabled, 33 SharedLibraryLocked, 34 PendingLicense, 35 OtherSessionPlaying, 36 CorruptDownload, 37 CorruptDisk, 38 FilePermissions, 39 FileLocked, 40 MissingContent, 41 Requires64BitOS, 42 MissingUpdateFiles, 43 NotEnoughDiskQuota, 44 LockedSiteLicense, 45 ParentalControlBlocked, 46 CreateProcessFailure, 47 SteamClientOutdated, 48 PlaytimeExceeded, 49 CorruptFileSignature, 50 MissingInstalledFiles, 51 CompatibilityToolFailure, 52 UnmountedUninstallPath, 53 InvalidBackupPath, 54 InvalidPasscode, 55 ThirdPartyUpdater, 56 ParentalPlaytimeExceeded, 57 Max.

`SteamClient.Installs` ([Installs.d.ts](https://app.unpkg.com/@steambrew/client@5.5.0/files/build/globals/steam-client/Installs.d.ts)):
- `CancelInstall(): void` closes the install wizard if open. It does not cancel a running download.
- `ContinueInstall(): void`, `OpenInstallWizard(appIds: number[]): void`, `SetAppList(appIds: number[])`, `SetInstallFolder(folderIndex: number)`, `SetCreateShortcuts(desktop: boolean, systemMenu: boolean)`, `GetInstallManagerInfo(): Promise<InstallMgrInfo>`.
- `OpenUninstallWizard(appIds: number[], dontPrompt: boolean): void`.
- Events: `RegisterForShowInstallWizard`, `RegisterForShowFailedUninstall(cb(appId, reason: EAppUpdateError))`, `RegisterForShowConfirmUninstall`.

Cancel the install of a not-installed game: no dedicated method found. Candidate: `RemoveFromDownloadList(appId)` then `OpenUninstallWizard([appId], true)`. Unconfirmed; test live. `SteamClient.Apps` has no uninstall/download-app method except Flatpak ones (same App.ts).

Not confirmed from Decky Loader (@decky/ui) or SteamDB; Millennium types were the only source reached.

## Q4. steam:// URLs

- Confirmed (search summary of the [Valve Developer Wiki, Steam browser protocol](https://developer.valvesoftware.com/wiki/Steam_browser_protocol); page returned HTTP 403 to my fetch, so not read directly): `steam://install/<id>`, `steam://run/<id>`, `steam://gameproperties/<id>`, `steam://open/<component>` with "downloads" listed.
- `steam://validate/<id>`: listed in a Linux man page mirror only (not read). Unconfirmed.
- `steam://uninstall/<id>`: not found on the wiki. Behavior for a first-time download in progress: Unconfirmed.
- Pause/resume URL: none found. Unconfirmed (likely none).
- Millennium adds `steam://millennium/...` commands but they are plugin controls, not downloads ([doc](https://docs.steambrew.app/users/guides/millennium-protocol)).

## Q5. macOS registry.vdf and running app

- Confirmed locally (read-only check, 2026-10-19): `~/Library/Application Support/Steam/registry.vdf` exists. Structure: `Registry > HKLM > Software > Valve > Steam` and `Registry > HKCU > Software > Valve > Steam`. No `RunningAppID` key present (Steam was idle, no game running; so presence while running is not tested).
- Linux: `RunningAppID` under HKCU.Software.Valve.Steam existed, then new UI left it at 0. [steam-for-linux #9672](https://github.com/ValveSoftware/steam-for-linux/issues/9672), opened 2023-06-18, last comment 2026-07-24. Confirmed for Linux; macOS Unconfirmed. Assume unreliable.
- Other signal: `logs/gameprocess_log.txt` lines `AppID <n> adding PID <m>` and process exit lines, parsed by MoonDeck Buddy ([agent-device-hub #380](https://github.com/jimmie-potts/agent-device-hub/issues/380), 2026-09, secondary). File exists on this Mac; line format on macOS Unconfirmed (log was empty of AppID lines).
- Another: per-app `HKCU\Software\Valve\Steam\Apps\<appid>\Running` (Windows registry; secondary). Manifest bit 64 (AppRunning) in StateFlags is a candidate, Unconfirmed.

## Q6. steamloopback.host

- Confirmed locally: Steam logs show `https://steamloopback.host/index.html?...&PLATFORM=macos&ARCH=arm64` and `STARTUP ResourceHandler slow 4.5ms request:https://steamloopback.host/custom_fonts/clientui.uifont?MotivaSans-Regular` (`logs/webhelper_js.txt`, `logs/webhelper.txt`, 2026-10-18). The "ResourceHandler" wording suggests a CEF resource handler inside Steam, not a network server.
- Confirmed: the host maps to the `steamui` folder; files placed there are applied by skins ([SFP issue #50](https://github.com/PhantomGamers/SFP/issues/50)). The maintainer reported one file (`friends.custom.css`) not working there, so mixed results.
- `steamui/index.html` exists on this Mac under `Steam.AppBundle/Steam/Contents/MacOS/steamui/` (local check).
- Per-request disk read (open/fopen): Unconfirmed; no source or binary inspection. Whether any arbitrary new file path under steamui is served: Unconfirmed (SFP evidence is for CSS only).
- Known project serving extra files this way: SFP (Steam Friends Patcher) copies CSS into steamui; Millennium uses other mechanisms (not confirmed to use steamloopback.host). No project confirmed for JS/JSON asset serving.

## Open points

1. Live capture needed: manifest keys and timing during a download, pause line in content_log, StateFlags while paused.
2. Test `PauseAppUpdate` vs `RemoveFromDownloadList` on current macOS Steam.
3. Test steam://uninstall during a first download; test that a new file in steamui is served.
4. Verify upper StateFlags bit values (Lutris vs LinuxGSM conflict).

## Sources

- https://github.com/GameServerManagers/LinuxGSM-Docs/blob/master/steamcmd/errors.md (2015 table)
- https://raw.githubusercontent.com/lutris/lutris/master/lutris/util/steam/appmanifest.py
- https://github.com/pinkwah/steam-appmanifest/blob/master/README.md
- https://steamcommunity.com/discussions/forum/0/3004430047197048765
- https://techfuelhq.com/gaming/steam-slow-download-speed-2026/
- https://steamcommunity.com/groups/SteamClientBeta/discussions/0/3775742015034728598/?l=koreana&ctp=3 (2024-03)
- https://steamcommunity.com/discussions/forum/1/3183485686841141213/?ctp=3
- https://steamcommunity.com/discussions/forum/1/1736595227845010961 (2018)
- https://app.unpkg.com/@steambrew/client@5.5.0/files/src/globals/steam-client/Downloads.ts
- https://app.unpkg.com/@steambrew/client@5.5.0/files/src/globals/steam-client/App.ts
- https://app.unpkg.com/@steambrew/client@5.5.0/files/build/globals/steam-client/Installs.d.ts
- https://docs.steambrew.app/plugins/ts/client/src/interfaces/Downloads
- https://newreleases.io/project/github/SteamClientHomebrew/Millennium/release/v3.3.0
- https://developer.valvesoftware.com/wiki/Steam_browser_protocol (not read directly)
- https://docs.steambrew.app/users/guides/millennium-protocol
- https://github.com/ValveSoftware/steam-for-linux/issues/9672
- https://github.com/jimmie-potts/agent-device-hub/issues/380
- https://github.com/PhantomGamers/SFP/issues/50
- Local files: ~/Library/Application Support/Steam/registry.vdf and logs/*.txt (read 2026-10-19)
