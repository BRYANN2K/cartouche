# Compatibility fixtures

Recorded answers from the four sources and Steam, used by the builder tests instead of the network. `2026-10-19/` was recorded on 2026-10-19 with `record_fixtures.py` for Elden Ring (1245620), Apex Legends (1172470), Counter-Strike 2 (730) and Disco Elysium (632470). Its MacGamingDB rows for Elden Ring are the same 25 rows, in the same order, as the 2026-10-18 pull in `mockup/launcher.html`.

Each file keeps the shape the source serves, cut down:

| Folder | Source | What was cut | License of the data |
|---|---|---|---|
| `macgamingdb/` | MacGamingDB REST API, Elden Ring only, read by the app's tests. The builder never reads or publishes it | Other games. Store descriptions, screenshots, and each report's author, notes and screenshots | No data license published by MacGamingDB. Used with attribution |
| `applegamingwiki/` | AppleGamingWiki MediaWiki API | Pages other than the four. Everything but the infobox and `{{Compatibility/macOS}}`, and the notes fields | CC BY-NC-SA 3.0, AppleGamingWiki contributors |
| `protondb/` | ProtonDB export `reports_oct1_2026.tar.gz` | Games other than the four, reports older than 15 months, every answer but `verdict`, `onlineMultiplayerAttempted`, `onlineMultiplayerPlayed`, and all system info | ODbL 1.0, ProtonDB |
| `areweanticheatyet/` | AreWeAntiCheatYet `games.json` | Games other than the four, notes | MIT, Copyright (c) 2021 Starz0r, Curve |
| `steam/` | Steam `GetMostPlayedGames` | Nothing | Steam Web API |
