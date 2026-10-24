# Tasks

## 1. Consoles

- [x] 1.1 Console catalog (system, recommended core, glyph, BIOS needs) and enabled set; unit tests
- [x] 1.2 Sidebar section with +, Add Consoles sheet, right-click Remove; UI tests for add and remove, file-untouched check

## 2. Adding games

- [x] 2.1 Identifier: CRC32/MD5/SHA-1 against the libretro `.rdb`, `.cue`/`.chd` disc IDs, `.m3u` grouping; tests with legally redistributable homebrew fixtures and recorded database rows
- [x] 2.2 + sheet Console Games tab, identification list, console picker for unknown files, Back; UI tests including Windows/Console switching
- [x] 2.3 Watched folders with FSEvents; integration test copying a file in

## 3. Covers

- [x] 3.1 Thumbnail fetch by database name with URL escaping, cache, square cards; tests for names with parentheses, commas and ampersands

## 4. Panel and launch

- [x] 4.1 Panel sections in the documented order, More… sheet; snapshot tests light and dark
- [x] 4.2 Continue From from RetroArch state pictures; resume a slot through the session manager; integration test
- [x] 4.3 BIOS warning and disabled Play; Look applied live through SET_SHADER; tests
- [x] 4.4 CRT power-on, activity slot, Quit with auto save and play time; UI test

## 5. Acceptance

- [ ] 5.1 Evidence per scenario; APPFLOW and DESIGN updated by the docs agent; `openspec validate p13-console-library --strict` passes
