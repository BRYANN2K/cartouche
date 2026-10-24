# onboarding Specification

## Purpose
How Cartouche is installed without surprises (install script, disk image, Homebrew) and how its first launch detects what is on the Mac, offers five skippable steps, resumes after a quit and moves itself to Applications.

## Requirements

### Requirement: Install without the Gatekeeper warning
The README SHALL offer, as the recommended install, a one-line script fetched with curl that downloads the release, checks its SHA-256 and code signature, installs it in /Applications and opens it, so that macOS shows no "Not Opened" warning. The script SHALL be short, readable and published in the repository.

#### Scenario: No warning on a clean Mac
- **WHEN** the install command runs on a clean macOS 15 or 26 account
- **THEN** Cartouche opens without the "Not Opened" alert, and `xattr -p com.apple.quarantine /Applications/Cartouche.app` reports no such attribute

#### Scenario: Tampered download
- **WHEN** the downloaded archive's SHA-256 differs from the one published with the release
- **THEN** the script stops, deletes the archive, installs nothing and says why

### Requirement: Installing a non-notarized app
For the disk image and the Homebrew cask, the dmg window, the README and the cask caveats SHALL explain in three steps how to open Cartouche the first time on macOS 15 and 26, with screenshots in the README.

#### Scenario: First open from the dmg
- **WHEN** a user drags Cartouche to Applications and opens it, then follows the three steps shown in the dmg window
- **THEN** Cartouche opens, and later updates open without any Gatekeeper prompt

### Requirement: Detection before questions
The first launch SHALL show what Cartouche found on the Mac before asking anything: Steam and its account, CrossOver, Game Porting Toolkit, controllers, and folders that look like game folders.

#### Scenario: Found list
- **WHEN** Steam (signed in), a DualSense and ~/Games/ROMs exist
- **THEN** the welcome step lists Steam with the account name, the DualSense, and offers ~/Games/ROMs as a game folder, within 3 seconds

### Requirement: Short, skippable setup
Onboarding SHALL have at most five steps (Welcome, PC games, Consoles, Folders and privacy, Ready), each skippable, and SHALL ask for App Management only in the PC games step, before modifying Steam.

#### Scenario: Skip everything
- **WHEN** the user clicks Skip on every step
- **THEN** the library opens, nothing was downloaded or modified, and every choice is available in Settings

#### Scenario: Consoles step
- **WHEN** the user picks Super Nintendo and PlayStation in the Consoles step
- **THEN** only their cores are downloaded, and the PlayStation BIOS status is shown with the missing file named

### Requirement: Ends on something playable
The last step SHALL point to a game the user can play now, when one exists.

#### Scenario: Ready with Steam games
- **WHEN** onboarding ends with Steam connected and a free runner installed
- **THEN** the Ready step shows the most recently played installed game with a Play button

### Requirement: Onboarding resumes
Onboarding SHALL save the current step and choices after each step, and when Cartouche quits before the end, SHALL reopen on that step with a "Welcome back" banner and a Start Over button.

#### Scenario: Quit midway
- **WHEN** the user picks two consoles, reaches Folders and privacy, and Cartouche quits
- **THEN** on the next launch onboarding opens on Folders and privacy, the two consoles are still picked, and nothing already downloaded is downloaded again

### Requirement: Runs from Applications
When Cartouche is opened from outside /Applications (the disk image, Downloads, or a translocated path), it SHALL offer to move itself to /Applications and relaunch before onboarding starts, because permissions and updates are tied to that location.

#### Scenario: Opened from the disk image
- **WHEN** the user opens Cartouche directly from the mounted disk image
- **THEN** Cartouche shows "Move to Applications" with Move and Quit, and after Move it relaunches from /Applications/Cartouche.app

### Requirement: Signature explained honestly
The dmg window, README and first-open help SHALL say that Cartouche is signed with its own certificate, that this does not remove the first-open warning, and that it keeps updates and granted permissions from resetting.

#### Scenario: Wording check
- **WHEN** the dmg window and README install section are read
- **THEN** they never claim Apple verified Cartouche, and they state that the install script avoids the warning
