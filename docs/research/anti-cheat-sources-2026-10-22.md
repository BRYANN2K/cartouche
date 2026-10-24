# Anti-cheat sources for Cartouche

Research requested by the maintainer and delegated to Luna on 2026-10-22.

| Source | Useful data | Limits |
| --- | --- | --- |
| [AreWeAntiCheatYet](https://github.com/AreWeAntiCheatYet/AreWeAntiCheatYet) | Per-game anti-cheat names, community status, evidence links, change dates; public JSON under MIT. | Its scope is GNU/Linux. A status there does not establish Wine/macOS support. A fresh dataset download can contain old individual entries. |
| [Highball DB](https://gethighball.com/docs/data/) | Mac Apple Silicon/Wine data with provenance and distinctions between tested results, reports and predictions; public per-game JSON. | Recent project with limited verified coverage. Its anti-cheat dataset also interprets AWACY. Curated observations must be distinguished from automatic predictions. |
| [Heroic MacAnticheatData](https://github.com/Heroic-Games-Launcher/MacAnticheatData) | MIT JSON catalog useful for names and conservative Mac status. | Its README describes an AWACY transformation that marks EAC/BattlEye unsupported and other systems unknown. This is not a collection of new per-game Mac tests. |
| [ProtonDB exports](https://github.com/bdefore/protondb-data) | Community execution and multiplayer answers; monthly exports under ODbL and Database Contents License. | A working game or multiplayer report does not prove anti-cheat authentication or protected matchmaking in Cartouche. Native-build reports must not be treated as Wine tests. |
| [SteamDB](https://steamdb.info/app/730/info/) | Identification of anti-cheat technologies in Steam metadata, such as VAC. | No Wine/macOS compatibility verdict; no official public API for this use. |
| [PCGamingWiki](https://www.pcgamingwiki.com/wiki/Anti-cheat_middleware) | Middleware identification and game-specific documentation. | No systematic dataset of protected matchmaking under Wine/macOS. |

Use AWACY for identification and its own platform's status, ProtonDB for reading player experiences, and explicit dated Mac tests when available. Highball is a candidate for those Mac observations, subject to checking each record's provenance. Its curated data is CC0; AWACY-derived anti-cheat data retains MIT and ProtonDB-derived data retains ODbL. These are separate licenses, not a single license for every Highball field.

Keep four facts separate: detected anti-cheats, source-reported compatibility, tested Wine/macOS behavior, and protected matchmaking. Do not infer the last two from a middleware name, an aggregate execution score or solo play. [Valve's Proton documentation](https://partner.steamgames.com/doc/steamhardware/proton) describes platform-specific EAC/BattlEye integration and studio opt-in.

For CS2, the bundled Mac catalog says `Unknown` for VAC. Cartouche's earlier blanket VAC rejection was a local rule based on inherited README wording; it was removed. The bundled 29/29 multiplayer count comes from the October ProtonDB export. The current parser counts multiplayer answers without excluding native builds, so that figure cannot establish VAC support in Wine. Until a relevant test provides evidence, show the Mac verdict as unverified and link to the underlying reports.
