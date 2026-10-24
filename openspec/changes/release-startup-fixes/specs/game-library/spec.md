# Release startup fixes delta

## ADDED Requirements

### Requirement: Nonblocking library process state
View and menu construction SHALL NOT synchronously wait for process probes. GameMenu.items SHALL read cached per-game busy state. Busy refresh, Steam presence and uninstall probes/plans SHALL run off the main actor; user confirmation SHALL return to the main actor.

#### Scenario: Menu during process refresh
- **WHEN** a game menu is built while process state is being refreshed
- **THEN** menu construction reads cached state without waiting for lsof or pgrep

