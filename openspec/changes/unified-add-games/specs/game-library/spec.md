# Unified Add Games delta

## MODIFIED Requirements

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

