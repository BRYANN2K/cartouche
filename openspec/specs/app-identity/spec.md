# app-identity Specification

## Purpose
Cartouche's own identity on the Mac: bundle ID, data and log folders, update feed and key, icon, attribution to NotProton, and Steam-side names that never touch an installed NotProton.

## Requirements

### Requirement: Distinct identity
The app SHALL present itself as Cartouche, with bundle identifier `dev.bryann2k.cartouche`, and SHALL NOT show the name NotProton in any user-facing string except the attribution in About and README.

#### Scenario: Built app reports its identity
- **WHEN** the release build is inspected with `defaults read Cartouche.app/Contents/Info CFBundleIdentifier` and `CFBundleName`
- **THEN** the values are `dev.bryann2k.cartouche` and `Cartouche`

#### Scenario: No leftover NotProton strings
- **WHEN** all localized strings and SwiftUI view text are searched for "NotProton"
- **THEN** the only matches are the attribution line in the About window and the README credits section

### Requirement: Separate data
The app SHALL store its data in `~/Library/Application Support/Cartouche` and its logs in `~/Library/Logs/Cartouche`, and SHALL NOT read or write NotProton's folders.

#### Scenario: Fresh install creates its own folders
- **WHEN** Cartouche launches for the first time on a Mac that also has NotProton installed and configured
- **THEN** `~/Library/Application Support/Cartouche` exists and the modification time of every file under `~/Library/Application Support/notproton` is unchanged

### Requirement: Leaves NotProton untouched
The app SHALL use its own names inside Steam: dylib `cartouche.dylib`, compatibility tools `cartouche-proton*`, `cartouche-*` files in game prefixes, `CARTOUCHE_*` launch option variables and the `cartoucheWindows` library filter key, all defined in `cartouche_identity.h`. Install, Repair Steam and Remove Everything SHALL NOT modify or remove NotProton's dylib, its insert entry, its compatibility tools or its prefix files.

#### Scenario: Remove Everything leaves NotProton untouched
- **WHEN** a fixture Steam carries NotProton's injected dylib, its `notproton*` tools and its prefix files, and Remove Everything runs in Cartouche
- **THEN** those files are byte-identical afterwards, NotProton's insert entry is still declared, Steam is not restored, and Cartouche's own tool and folder are removed

#### Scenario: Repair refuses a Steam that NotProton injects
- **WHEN** Repair Steam runs on a Steam that carries NotProton's dylib
- **THEN** it stops with an error naming that dylib before stopping Steam or downloading anything, and the bundle is byte-identical

#### Scenario: Steam-side names come from one place
- **WHEN** the names used by the app, the dylib, the run script and the Steam UI patch are compared with `cartouche_identity.h`
- **THEN** they match, and no code outside that header names `notproton`

### Requirement: Own update feed
The app SHALL check for updates only at the Cartouche appcast URL and SHALL accept only updates signed with the Cartouche EdDSA key.

#### Scenario: Feed and key are Cartouche's
- **WHEN** `SUFeedURL` and `SUPublicEDKey` are read from the built Info.plist
- **THEN** the feed host is the Cartouche GitHub repository and the key differs from NotProton's key

#### Scenario: Foreign update is refused
- **WHEN** the app is pointed at an appcast whose item is signed with a different EdDSA key
- **THEN** Sparkle rejects the update and the installed version is unchanged

### Requirement: Attribution and licensing
The repository and the app SHALL credit NotProton and its authors, keep the GPL-3.0 license, and state that Cartouche is not affiliated with NotProton, Valve, Apple or CodeWeavers.

#### Scenario: Attribution is present
- **WHEN** README.md, NOTICE and the About window are read
- **THEN** each contains the NotProton credit, the GPL-3.0 notice and the non-affiliation sentence

#### Scenario: About links the website
- **WHEN** the About window is opened
- **THEN** its first credits line is https://cartouche.bryann2k.dev, and clicking it opens the site in the default browser

### Requirement: App icon
The app SHALL use the Cartouche icon in Default and Dark appearances and a template glyph in the menu bar.

#### Scenario: Icon appears in Finder and Dock
- **WHEN** the built app is shown in Finder and launched
- **THEN** Finder and the Dock show the cartridge icon, and switching macOS to Dark mode shows the dark variant
