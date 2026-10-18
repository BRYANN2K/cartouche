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

**Coach mode.** An experimental feature in which an AI reads a console game's memory through RetroArch's MCP tools and gives tips. Memory addresses come from RetroAchievements definitions.

## Agents

**MCP (Model Context Protocol).** An open protocol that lets AI agents call tools in an app. Cartouche has an MCP server for itself. RetroArch has another one, which Cartouche uses.

## Project process

**Phase.** One unit of work in `docs/ROADMAP.md`, numbered P0, P1 and so on. Each is one OpenSpec change.

**Wave.** A group of phases that can run in parallel because they touch different directories.

**Evidence.** The proof that a scenario holds: a test name, command output or screenshot, recorded in `evidence.md`.

**OpenSpec.** The spec format used here: a change has a proposal, specs with scenarios, tasks, and sometimes a design.

**Scenario.** One WHEN and THEN example in a spec. It is an acceptance criterion.
