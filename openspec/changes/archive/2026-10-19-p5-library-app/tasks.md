# Tasks

## 1. Steam import

- [x] 1.1 Export owned apps, collections and play data from the injected Steam UI code to the app's data folder; test with a fixture Steam UI page — Not in v0.1.0 (maintainer decision 2026-10-19): the library comes from Steam's own files
- [x] 1.2 Fallback reader for `libraryfolders.vdf`, `appmanifest_*.acf` and `loginusers.vdf`; unit tests with fixture files
- [x] 1.3 Steam not installed screen with the three install paths; snapshot test

## 2. Window and library

- [x] 2.1 Sidebar, toolbar, grid, cover states (gray, selected, favorite); snapshot tests in light and dark
- [x] 2.2 Favorites, hidden games, search with empty state; unit tests for persistence and filtering
- [x] 2.3 Game panel and Details sheet matching the mockup order; snapshot test on Elden Ring fixture

## 3. Menus and settings

- [x] 3.1 Context menu, menu bar menus, status item, shortcuts; UI tests for ⌘D and ⌘I
- [x] 3.2 Settings window (General, Library, Accounts, Compatibility, Privacy); snapshot tests

## 4. States and platforms

- [x] 4.1 Loading, empty, offline, expired, error states; snapshot test per state
- [ ] 4.2 macOS 15 material fallback and Reduce Motion / Transparency; snapshot runs on macOS 15 and 26 runners

## 5. Acceptance

- [ ] 5.1 Evidence per scenario; APPFLOW and DESIGN docs by the docs agent; `openspec validate p5-library-app --strict` passes
