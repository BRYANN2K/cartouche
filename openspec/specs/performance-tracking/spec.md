# performance-tracking Specification

## Purpose
How Cartouche measures FPS per play session and per setup, stores it on the Mac, shows the player's own averages and setup comparison, and keeps sharing off unless the user opts in.

## Requirements

### Requirement: Measurement
While a Windows game runs, the app SHALL record presented frames per second, skipping the first 30 seconds, loading screens and time when the game is not frontmost.

#### Scenario: Accuracy
- **WHEN** a test scene locked at 60 fps runs for 5 minutes with each backend (D3DMetal, DXMT, DXVK)
- **THEN** the recorded average is 60 ± 1 fps for each

#### Scenario: Background time is ignored
- **WHEN** the game is not frontmost for 2 minutes of a 10-minute session
- **THEN** the session's measured time is 8 minutes (± 5 seconds, minus the first 30 seconds)

#### Scenario: Low overhead
- **WHEN** the same benchmark runs with and without measurement
- **THEN** the average FPS differs by less than 1%

### Requirement: Your play
The game panel SHALL show the average FPS weighted by play time, the 1% low and the total play time, and a comparison of every setup used.

#### Scenario: Weighted average
- **WHEN** a game has 14.2 h at 56 fps and 1.1 h at 34 fps
- **THEN** the panel shows 54 fps, not 45

#### Scenario: Compare setups
- **WHEN** the user opens Compare Setups for a game played with three setups
- **THEN** a table lists each setup with average, 1% low and play time, marks the best, and offers to use it

### Requirement: Privacy
Measurements SHALL stay on the Mac unless the user turns on sharing, and sharing SHALL send only the Mac model, setup, settings and FPS.

#### Scenario: Off by default
- **WHEN** the app runs with default settings and network traffic is captured during and after a session
- **THEN** no request carries play data

#### Scenario: What is shared
- **WHEN** sharing is on and a session ends
- **THEN** the request body contains chip, RAM, macOS version, runner, backend, settings and FPS, and no account name, path or Steam ID

### Requirement: Injection is safe
If the frame counter cannot be injected, the game SHALL still start and the app SHALL say measurement is unavailable for that runner.

#### Scenario: Blocked injection
- **WHEN** the runner's binaries refuse the injected library
- **THEN** the game runs normally and the panel shows "FPS can't be measured with this runner"
