## ADDED Requirements

### Requirement: Steam library import
The app SHALL list the signed-in Steam account's games with their collections and last played date, read from Steam's own local files (`libraryfolders.vdf`, `appmanifest_*.acf`, `loginusers.vdf`, the cloud-storage collections file), whether Steam is running or closed. A `steam-library.json` export MAY extend the list when one is present; the Steam-side writer of that export is not part of v0.1.0 (maintainer decision 2026-10-19).

#### Scenario: Import from Steam
- **WHEN** Steam is running and signed in with an account that has N installed games
- **THEN** within 10 seconds the library shows those N Steam games, and the toolbar reads "<N> games. Signed in as <account>"

#### Scenario: Steam closed
- **WHEN** Steam is closed
- **THEN** the library shows the games read from Steam's local files, with installed status from its manifests

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
The library SHALL group sources under PC and Consoles, SHALL support square covers for console games next to 2:3 covers for PC games, and the toolbar's Add Games SHALL offer both Windows Game and Console Games.

#### Scenario: Sidebar structure
- **WHEN** the app starts with Steam signed in and no console added
- **THEN** the sidebar shows Library (All Games, Favorites), PC (Steam, Epic Games, GOG, Amazon Games, Windows Installers) and an empty Consoles section with a + button

#### Scenario: Section titles are not repeated
- **WHEN** a single source or console is selected
- **THEN** the grid has no section header repeating the toolbar title; section headers appear only in All Games

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
