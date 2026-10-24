# Onboarding v2 delta

## MODIFIED Requirements

### Requirement: Short, skippable setup
Onboarding SHALL have at most seven steps — Welcome with the detection scan, Windows games, Stores, Consoles, Controller, Permissions, storage and privacy, Ready — each skippable, and SHALL ask for App Management only in the Windows games step, before modifying Steam. The Windows games step SHALL offer Cartouche Wine preselected as the default runner and a way to pick the user's own Game Porting Toolkit disk image.

#### Scenario: Seven steps in order
- **WHEN** onboarding runs on a first launch
- **THEN** the steps appear in the order Welcome, Windows games, Stores, Consoles, Controller, Permissions/storage/privacy, Ready, and each step shows a Skip control

#### Scenario: Skip everything
- **WHEN** the user clicks Skip on every step
- **THEN** the library opens, nothing was downloaded or modified, and every choice is available in Settings

#### Scenario: Windows games defaults
- **WHEN** the user reaches the Windows games step and no runner is ready
- **THEN** Cartouche Wine is preselected for installation and picking a Game Porting Toolkit disk image is offered; choosing neither and skipping leaves no runner installed

#### Scenario: Stores step
- **WHEN** the user skips the Stores step
- **THEN** no store is signed in and Epic, GOG and Amazon remain connectable from Settings

#### Scenario: Consoles step
- **WHEN** the user picks Super Nintendo and PlayStation in the Consoles step
- **THEN** only their cores are downloaded, and the PlayStation BIOS status is shown with the missing file named

#### Scenario: Controller step
- **WHEN** the user reaches the Controller step with no controller connected
- **THEN** the step says no controller is connected and can be skipped; with a controller connected it shows the controller and its live state

## ADDED Requirements

### Requirement: Onboarding work runs in the background
Downloads and installs started during onboarding SHALL run as background tasks that do not block moving between steps, SHALL be visible in Activity, and SHALL keep their state across a relaunch.

#### Scenario: Download continues across steps
- **WHEN** a runner download is started in the Windows games step and the user moves to the next step
- **THEN** the download continues and its progress is shown in Activity

#### Scenario: Task state survives relaunch
- **WHEN** Cartouche quits while an onboarding download is in progress and is relaunched
- **THEN** onboarding reopens on the saved step and the task is restored: it resumes, or it is shown as interrupted with a way to retry
