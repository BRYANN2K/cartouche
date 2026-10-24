## ADDED Requirements

### Requirement: Sign in without seeing passwords
The app SHALL sign in to each store through the store's own web page and SHALL store only the resulting token, in the Keychain.

#### Scenario: Epic sign-in
- **WHEN** the user clicks "Sign In with Epic Games…" and completes Epic's page
- **THEN** the library lists the account's Epic games within 15 seconds, and no password field ever appears in Cartouche

#### Scenario: Expired session
- **WHEN** a store token expires
- **THEN** the sidebar shows a red badge on the store and its page shows "Your <store> session expired" with Sign In Again, while installed games stay playable

### Requirement: Store games behave like Steam games
Store games SHALL install, update, verify, launch and uninstall from Cartouche with the same setup, estimate and FPS features as Steam games.

#### Scenario: Install and play
- **WHEN** the user installs a free Epic game and presses Play
- **THEN** it downloads with progress in the activity slot and launches with the runner and backend shown in its setup

#### Scenario: Cloud saves
- **WHEN** a GOG game with cloud saves is played on two Macs
- **THEN** the save made on the first appears on the second after its next launch

### Requirement: Honest capability list
Each store page SHALL state what works for that store (downloads, cloud saves, online features) according to the bundled client.

#### Scenario: Amazon
- **WHEN** the Amazon Games sign-in page is shown
- **THEN** it lists cloud saves and online features as "Not supported yet" if nile does not support them in the bundled version
