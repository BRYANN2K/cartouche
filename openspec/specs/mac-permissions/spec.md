# mac-permissions Specification

## Purpose
Which macOS permissions Cartouche asks for, when and how it explains them, how the user recovers from a denial, and how Cartouche relaunches itself when macOS requires it.

## Requirements

### Requirement: Ask only when needed, explain first
Cartouche SHALL request a macOS permission only when the user starts the feature that needs it, after a one-sentence Cartouche explanation, and SHALL never request a permission no feature needs.

#### Scenario: Notifications are not asked at launch
- **WHEN** Cartouche launches for the first time
- **THEN** no notification prompt appears; it appears only after the first download or install finishes, preceded by Cartouche's explanation

#### Scenario: Unused permissions are never requested
- **WHEN** the app binary and Info.plist are inspected
- **THEN** there is no usage description or request for Full Disk Access, Screen Recording, Camera, Microphone or Bluetooth

### Requirement: Clear state and recovery
Settings > Privacy SHALL list every permission Cartouche uses with its state (Allowed, Not allowed, Not asked yet) and the feature it serves, and SHALL open the exact System Settings pane to change it.

#### Scenario: Recover App Management
- **WHEN** App Management was denied and the user clicks Open System Settings next to it
- **THEN** System Settings opens on Privacy & Security > App Management, and after the user allows Cartouche, the state shows Allowed without restarting Cartouche

### Requirement: Denied never means silent failure
When a permission is denied, the feature that needs it SHALL say so where the user is, name the permission, and offer the fix, while other features keep working.

#### Scenario: Downloads denied
- **WHEN** Downloads access is denied and the user turns on "Suggest installers that appear in Downloads"
- **THEN** the option turns back off with "Cartouche can't read Downloads. Allow it in System Settings." and drag and drop of an installer still works

#### Scenario: Steam modification denied
- **WHEN** App Management is denied during onboarding
- **THEN** the Steam step shows the reason and Open System Settings, and the rest of onboarding (consoles, folders) can continue

### Requirement: Permissions survive updates
Permissions granted to Cartouche SHALL remain granted after a Sparkle update.

#### Scenario: Update keeps grants
- **WHEN** Accessibility and Notifications are allowed and Cartouche updates from v0.1.0 to v0.1.1
- **THEN** both are still allowed and no prompt appears

### Requirement: Relaunch handled by Cartouche
For a permission that macOS applies only after the app restarts (Input Monitoring), Cartouche SHALL say so in its explanation before the macOS prompt, SHALL offer its own Relaunch button when the user chose Later in the macOS alert, SHALL never relaunch while a game is running, and SHALL reopen on the screen the user was on.

#### Scenario: Quit and Reopen
- **WHEN** the user turns on key remapping in Controls, allows Input Monitoring in System Settings and clicks Quit & Reopen
- **THEN** Cartouche reopens on the same Controls screen within 5 seconds and remapping is on, with no second prompt

#### Scenario: Later
- **WHEN** the user clicks Later in the macOS alert
- **THEN** Controls shows "Relaunch Cartouche to finish" with a Relaunch button, the option shows "Waiting for a relaunch", and the rest of Cartouche keeps working

#### Scenario: Game running
- **WHEN** the user clicks Relaunch while a game launched by Cartouche is running
- **THEN** Cartouche waits until the game exits, then relaunches, and says so in the banner

### Requirement: No relaunch during onboarding
Onboarding SHALL NOT request any permission that needs a relaunch to apply.

#### Scenario: Onboarding permissions
- **WHEN** onboarding is completed with every option turned on
- **THEN** the only macOS prompts shown are App Management and Downloads, and Cartouche is never asked to quit

#### Scenario: App Management not yet applied
- **WHEN** App Management is allowed and Try Again still gets a write refusal
- **THEN** the Steam step offers Relaunch Cartouche, and after the relaunch onboarding reopens on the PC games step
