# Unified Add Games delta

## ADDED Requirements

### Requirement: Common Add Games entry
Windows installers and installed-game folders SHALL enter through the unified Add Games sheet, opened by the toolbar + or a library-window drop. The sheet SHALL offer a drop zone and Choose… for files or folders of any type. Automatic classification SHALL route installers to installer analysis and installed-game folders to import; it SHALL NOT require a separate Windows Games… entry or execute a game as a setup merely because it is an exe.

#### Scenario: Installer routed from Add Games
- **WHEN** the user drops or chooses an installer or its folder through Add Games
- **THEN** automatic detection opens the installer flow with those inputs, without requiring a platform choice

#### Scenario: Installed game routed from Add Games
- **WHEN** the user drops or chooses an already-installed Windows-game folder through Add Games
- **THEN** automatic detection opens the installed-game import flow rather than running its executable as setup

