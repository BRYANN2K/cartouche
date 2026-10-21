# Glossary

Plain definitions of the terms used in Cartouche docs and specs. Read by contributors and curious users.

## Windows games

**Runner.** The program that runs Windows software on the Mac. Cartouche has three kinds: CrossOver, a Wine build, and Apple's Game Porting Toolkit.

**Wine.** An open-source layer that runs Windows programs on other systems. Most runners are Wine builds.

**Backend.** The layer that turns a game's graphics calls into Metal, the Mac graphics API. The user picks one per game.
- **D3DMetal.** Apple's translation layer, part of the Game Porting Toolkit and CrossOver. Strongest for DirectX 12. Never redistributed by Cartouche.
- **DXMT.** An open-source DirectX 11 to Metal layer. Strongest for DirectX 11.
- **DXVK.** Translates DirectX to Vulkan, which runs on Metal through MoltenVK. Good for older games.
- **wined3d.** Wine's own translation to OpenGL. A fallback.

**Prefix.** A folder that holds one Windows environment: a fake C: drive, registry and settings. Cartouche uses one prefix per installed game.

**Setup.** A game's chosen runner, backend, CPU translation and environment variables. Also the section of the game panel that shows them. Not to be confused with `setup.exe`, a Windows installer.

**Compatibility tool.** A Steam feature that runs a Windows game with a given program. Cartouche registers one tool per valid runner and backend pair, named `<runner> · <backend>`.

**Steam Play.** Steam's way of running Windows games on other systems through a compatibility tool. Cartouche adds it to the Mac Steam client.

**Rosetta.** Apple's translator that runs x86_64 code on Apple silicon. Cartouche always uses it for installers.

**FEX.** An alternative x86 translator. Cartouche offers it only on macOS 26.

**Estimate.** The expected rating, FPS and settings for the user's own Mac, computed from reports on comparable Macs.

## Consoles

**Core (libretro).** A plugin that emulates one console or a family of consoles inside RetroArch. Cartouche downloads cores per console and never bundles them.

**RetroArch.** The open-source emulator frontend that loads cores. Cartouche bundles its own build and drives it.

**BIOS.** Firmware files some consoles need to run games. The user must supply them. Cartouche reports what is missing and never provides them.

**ROM.** A file with the contents of a game cartridge or disc. Cartouche works only with files the user already has.

**Time Machine.** Cartouche's name for the browsable list of save states with pictures. Used by Continue From.

**Netplay.** Playing a console game with a friend over the network, through RetroArch's own netplay. Cartouche lists hosted games from libretro's lobby and from the local network.

**RetroAchievements.** A community service that gives retro games achievements. The user signs in once; the token stays in the Keychain.

**Hardcore.** A RetroAchievements mode with no save states and no rewind. Cartouche also refuses input tools to a Hardcore session.

**Standalone emulator.** An emulator that is an app of its own (Dolphin, Ryubing and others), not a libretro core. Cartouche detects installed ones and can launch a console's games with them.

**Coach mode.** An experimental feature in which an AI reads a console game's values through Cartouche's own MCP relay and gives tips. The value names come from the game's RetroAchievements Rich Presence definition.

## Stores

**Store client.** The open-source command-line tool that talks to a game store for Cartouche: legendary (Epic), gogdl (GOG), comet (GOG online features) and nile (Amazon). Each is downloaded pinned from its GitHub release.

**Token.** What a store, or RetroAchievements, returns after a sign-in on its own page. Stored only in the Keychain.

**Cloud saves.** Save files a store syncs between Macs. Works for Epic and GOG games; Amazon has none at the pinned nile.

## Agents

**MCP (Model Context Protocol).** An open protocol that lets AI agents call tools in an app. Cartouche's own MCP server is planned (P11). RetroArch has one, which Cartouche uses and relays.

## Project process

**Phase.** One unit of work in `docs/ROADMAP.md`, numbered P0, P1 and so on. Each is one OpenSpec change.

**Wave.** A group of phases that can run in parallel because they touch different directories.

**Evidence.** The proof that a scenario holds: a test name, command output or screenshot, recorded in `evidence.md`.

**OpenSpec.** The spec format used here: a change has a proposal, specs with scenarios, tasks, and sometimes a design.

**Scenario.** One WHEN and THEN example in a spec. It is an acceptance criterion.

**Translation glossary.** French UI terms follow `docs/l10n/glossary-fr.md`.
