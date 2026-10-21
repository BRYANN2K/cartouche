# game-library Specification

## Purpose
Cartouche shows one library for PC and console games, built from Steam's own files and the games Cartouche installed, with covers and every game state.

## Requirements

### Requirement: Steam library import
The app SHALL use the signed-in Steam account’s SteamExport v1 `steam-library.json` for the full owned-games list, collections and play data. The injected dylib SHALL register a WebUI route using the same mechanism as compatsvc’s routes. The route SHALL require a random token generated per Steam launch and known only to Cartouche’s injected page script. The dylib SHALL validate the token and payload before atomically replacing the export. This writer is required for v0.1.0 (maintainer decision 2026-10-20; ADR 0022).

The importer SHALL merge installed games and installed status from `appmanifest_*.acf`. It SHALL use `localconfig.vdf` for play data only, never ownership. An export from a different known account SHALL NOT populate the current account’s library. No loopback HTTP listener, public Steam profile or user Web API key SHALL be required.

#### Scenario: Import from Steam
- **WHEN** Steam is running and signed in with an account that has N owned games, including uninstalled games, and its injected page submits a valid export
- **THEN** within 10 seconds the library shows those N owned games, merges any additional installed games from manifests, and names the signed-in account in the toolbar

#### Scenario: Reject an unauthorized page
- **WHEN** a route request has no token, an incorrect token, or a token from a previous Steam launch
- **THEN** the dylib rejects the request and the previous export remains unchanged

#### Scenario: Reject invalid export data
- **WHEN** a request has the current token but an invalid SteamExport v1 payload
- **THEN** the dylib rejects the payload and the previous export remains readable and unchanged

#### Scenario: Atomic replacement
- **WHEN** writing a valid replacement is interrupted before the atomic replacement completes
- **THEN** the previous export remains readable and the app never reads a partial replacement

#### Scenario: Steam closed
- **WHEN** Steam is closed and an account-matched export exists, even if stale
- **THEN** the library shows that last export with a cached/stale label and installed status from manifests, without inferring ownership from localconfig.vdf

#### Scenario: No matching export
- **WHEN** no export exists for the current known account
- **THEN** the library shows installed games from manifests without claiming a complete owned-games list, and play data alone creates no library entry

#### Scenario: Account isolation
- **WHEN** the stored export belongs to a different known Steam account
- **THEN** the importer ignores that export for the current account

#### Scenario: Steam not installed
- **WHEN** Steam is not installed
- **THEN** the Steam source shows "Install Steam" with Download Steam (Valve installer), Install with Homebrew (only if Homebrew is present) and Locate Steam

### Requirement: Library browsing
The library SHALL group games by source, show not-installed games in black and white, and let the user favorite, search, hide and open any game.

#### Scenario: Not installed is gray, selected is in color
- **WHEN** a not-installed game is displayed, then selected
- **THEN** its cover is grayscale, then full color while selected

#### Scenario: Favorite from the cover
- **WHEN** the user clicks the star at the top left of a cover
- **THEN** the star fills, the game appears under Favorites, and the choice survives a relaunch

#### Scenario: Search
- **WHEN** the user types "zelda" and no game matches
- **THEN** the grid is replaced by "No games match “zelda”" with Clear Search, and the toolbar reads "Search, 0 results"

### Requirement: Game panel
The panel SHALL show, for the selected game: Play or Install, your play stats when they exist, the estimate for this Mac, anti-cheat on Linux when relevant, graphics reported on Macs, and the setup; sources and rare settings go behind Details.

#### Scenario: Panel content
- **WHEN** Elden Ring is selected on the 2026-10-18 fixture data
- **THEN** the panel shows, in this order, Play, Expected on This Mac, Anti-Cheat on Linux, Graphics Reported on Macs and Setup, and the Details sheet holds AppleGamingWiki, the Mac picker, the HUD and the sources

### Requirement: Screen states
Every screen SHALL have its loading, empty, error and offline states as listed in `mockup/AUDIT.md`.

#### Scenario: States are reachable
- **WHEN** the UI test suite drives each state (loading, empty library, offline, expired session, Steam not installed, no search result)
- **THEN** each state renders its documented content, verified by snapshot tests

### Requirement: Native look on both macOS versions
The app SHALL use Liquid Glass materials on macOS 26 and standard materials on macOS 15, and SHALL honor Reduce Motion and Reduce Transparency.

#### Scenario: macOS 15
- **WHEN** the app runs on macOS 15
- **THEN** every screen renders without missing controls, verified by snapshot tests on a macOS 15 runner

#### Scenario: Reduce Motion
- **WHEN** Reduce Motion is on
- **THEN** cover tilt, grid entrance and sheet springs are replaced by fades or no animation

### Requirement: Keyboard and menus
Every action in the context menu SHALL also be reachable from the menu bar, and the main actions SHALL have shortcuts (Play ⌘↩, Get Info ⌘I, Favorite ⌘D, Settings ⌘,, Find ⌘F).

#### Scenario: Shortcuts work
- **WHEN** a game is selected and the user presses ⌘D
- **THEN** the game is added to Favorites

### Requirement: Built for PC and console games
The library SHALL group sources under PC and Consoles and SHALL support square covers for console games next to 2:3 covers for PC games. The toolbar + SHALL open one Add Games sheet with a drop zone and Choose… for files or folders of any type. Dropping on the library window SHALL open the same sheet. Separate Windows Games… and Console Games… entries SHALL NOT be offered. Automatic detection SHALL route inputs to the matching installer, installed-game import, console ROM import or other supported flow through the existing DropClassifying protocol.

#### Scenario: Sidebar structure
- **WHEN** the app starts with Steam signed in and no console added
- **THEN** the sidebar shows Library (All Games, Favorites), PC (Steam, Epic Games, GOG, Amazon Games, Windows Installers) and an empty Consoles section with a + button

#### Scenario: Section titles are not repeated
- **WHEN** a single source or console is selected
- **THEN** the grid has no section header repeating the toolbar title; section headers appear only in All Games

#### Scenario: One toolbar entry
- **WHEN** the user clicks the toolbar +
- **THEN** one Add Games sheet opens with a drop zone and Choose… for files or folders of any type, without a Windows Games… or Console Games… choice

#### Scenario: Library-window drop
- **WHEN** the user drops files or folders on the library window
- **THEN** the same Add Games sheet opens with those inputs and runs automatic detection

#### Scenario: Choose inputs
- **WHEN** the user selects files or folders with Choose… in Add Games
- **THEN** those inputs use the same detection and routing as a drop, without a platform-specific file-type filter

### Requirement: Covers for PC games
Every PC game SHALL have a 2:3 cover, taken in this order: Steam's library art for its Steam App ID (from Steam's local cache first, then Steam's CDN), the store's own art (P10), a cover the user dropped on the game, and finally a cover drawn from the game's name and its executable icon. The user's choice SHALL always win.

#### Scenario: Steam game offline
- **WHEN** a Steam game was shown once and the Mac goes offline
- **THEN** its cover still shows, read from Steam's local library cache or Cartouche's cache

#### Scenario: User override
- **WHEN** the user drops an image on a game's cover and confirms
- **THEN** that image is used from then on and survives a library refresh

#### Scenario: Nothing found
- **WHEN** no art exists for a game
- **THEN** the cover shows the game's name and its exe icon on a plain background, never a broken image

#### Scenario: Privacy-gated cover search
- **WHEN** an installer game has no known Steam App ID and online lookups are disabled
- **THEN** automatic cover fallback sends no Steam name search and the library shows a local placeholder or cached cover

#### Scenario: User cover search
- **WHEN** online lookups are enabled and the user picks a result in Change Cover > Search Steam
- **THEN** the shared Steam lookup path supplies the result and the selected cover is saved as the user’s choice

### Requirement: Nonblocking library process state
View and menu construction SHALL NOT synchronously wait for process probes. GameMenu.items SHALL read cached per-game busy state. Busy refresh, Steam presence and uninstall probes/plans SHALL run off the main actor; user confirmation SHALL return to the main actor.

#### Scenario: Menu during process refresh
- **WHEN** a game menu is built while process state is being refreshed
- **THEN** menu construction reads cached state without waiting for lsof or pgrep
