## ADDED Requirements

### Requirement: One activity slot
The sidebar SHALL show the most important ongoing activity, in this order: running game, install, downloads, updates; and SHALL hide the slot when nothing is going on.

#### Scenario: Priority
- **WHEN** a game is running while a download is in progress
- **THEN** the slot shows the running game with its FPS and Quit, and the download is still listed in the status menu

#### Scenario: Nothing to show
- **WHEN** no game runs and nothing downloads, installs or updates
- **THEN** the slot is hidden

### Requirement: Download progress
Steam downloads of library games SHALL show progress in the activity ring and in the game panel, with Pause and Cancel acting on Steam.

#### Scenario: Pause from Cartouche
- **WHEN** the user clicks Pause on a downloading game
- **THEN** Steam pauses that download within 3 seconds and the ring shows the paused symbol

### Requirement: Cover reveal
While a game downloads or installs, its cover SHALL turn from black and white to color from the bottom up in step with progress, and SHALL respect Reduce Motion.

#### Scenario: Progress drives the reveal
- **WHEN** a download is at 50%
- **THEN** about the lower half of the cover is in color, and the shader renders at 60 fps on an M1 without raising the app's CPU use above 5%

#### Scenario: Reduce Motion
- **WHEN** Reduce Motion is on
- **THEN** the reveal is a static color/gray split with no moving edge or embers

### Requirement: Notifications
The app SHALL post a macOS notification when a download or install finishes or fails, with one relevant action.

#### Scenario: Ready to play
- **WHEN** a download finishes while the app is in the background
- **THEN** a notification "<Game> is ready to play" appears with a Play action that launches the game
