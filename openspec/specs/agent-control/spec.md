# agent-control Specification

## Purpose
Cartouche lets AI agents drive it over MCP: a bundled stdio helper on a private socket and an optional loopback HTTP transport with a token, read and action tools behind access levels, approvals, an action log with undo, and a secret and path scan on everything it returns.

## Requirements

### Requirement: Connectable server
Cartouche SHALL expose an MCP server that standard clients can add with one command, and SHALL keep the HTTP transport off unless the user turns it on.

#### Scenario: Claude Code connects
- **WHEN** the user runs `claude mcp add cartouche -- cartouche-mcp` and asks for the game list
- **THEN** the client lists Cartouche's tools and `list_games` returns the library

#### Scenario: HTTP is local only
- **WHEN** the HTTP transport is on
- **THEN** it listens on 127.0.0.1 only and rejects requests without the token with HTTP 401

### Requirement: Access levels and confirmation
Every tool SHALL belong to an access level, the server SHALL refuse tools above the level set in Settings, and tools that install, delete or run an executable SHALL wait for the user's approval in the app.

#### Scenario: Refused above level
- **WHEN** the level is Read only and an agent calls `launch_game`
- **THEN** the call fails with an error naming the required level, and nothing is launched

#### Scenario: Install needs approval
- **WHEN** an agent calls `install_from_installer` at Standard level
- **THEN** a notification asks "Claude wants to install <Game> (<size>). Allow?", and the tool returns only after Allow or Deny

### Requirement: Useful repair loop
An agent SHALL be able to read why a game or an install failed and apply a documented fix without shell access.

#### Scenario: Diagnose and fix a crash
- **WHEN** a game crashed on launch with a missing DLL and an agent calls `diagnose`
- **THEN** the result names the DLL and proposes a `set_game_config` or `run_winetricks` change that, once applied, lets the game start

#### Scenario: Retry an install
- **WHEN** an install failed with an unarc.dll error and an agent calls `retry_install` with `single_thread`
- **THEN** the new attempt runs with the decompressors limited to one thread, visible in the install log

### Requirement: Accountability
Every agent action SHALL appear in Settings > Agents with the client name and time, and configuration changes SHALL be undoable.

#### Scenario: Undo a config change
- **WHEN** an agent changed a game's backend and the user clicks Undo in the action log
- **THEN** the previous backend is restored and the log records the undo

### Requirement: No secrets exposed
No tool SHALL return store tokens, passwords, Keychain items, or files outside the app's data folder and folders the user granted.

#### Scenario: Secret scan
- **WHEN** a test client calls every read tool and the responses are scanned for token patterns and paths outside allowed roots
- **THEN** the scan finds nothing

### Requirement: One server for every kind of game
The MCP server SHALL expose PC and console games through the same library tools, and SHALL be the only way agents reach RetroArch: Cartouche relays console actions to its bundled RetroArch and applies its own access levels first.

#### Scenario: Console games are listed
- **WHEN** consoles are enabled (P12) and an agent calls `list_games` with source `snes`
- **THEN** the result lists the Super Nintendo games with their core and last save state, from the same tool used for PC games

#### Scenario: No direct RetroArch access
- **WHEN** an agent tries to reach RetroArch's own MCP endpoint
- **THEN** there is none to reach: Cartouche starts RetroArch with `--mcp-stdio` only, so the only channel is Cartouche's pipe

#### Scenario: Hardcore is protected
- **WHEN** a game runs with Hardcore achievements on and an agent calls a tool that would send input to it
- **THEN** Cartouche refuses the call before RetroArch sees it, with an error naming Hardcore mode
