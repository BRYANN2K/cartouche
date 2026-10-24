# Tasks

## 1. Build

- [x] 1.1 Add the RetroArch submodule pinned to a commit with `network/mcp_server.c`; record the commit in docs
- [ ] 1.2 CI job building RetroArch.app from `pkg/apple`, signing it, embedding it; verify `--version` names the commit; run twice to check reproducibility
- [x] 1.3 Repository scan for RetroArch or core binaries in CI; prove it fails on a planted fixture

## 2. Session manager

- [x] 2.1 Start with `--mcp-stdio` and `--appendconfig`; read `tools/list`; contract tests against the pinned commit
- [x] 2.2 Load content, GET_STATUS, STATE, SCREENSHOT, stop; integration test with a free homebrew test ROM and a small core
- [x] 2.3 Prove the user's `retroarch.cfg` hash is unchanged after 10 runs

## 3. Cores and BIOS

- [x] 3.1 Core download, verification record, update and delete; tests with a local fixture server
- [x] 3.2 `.info` parser for extensions and BIOS MD5; BIOS status per console; unit tests with fixtures, grep that no BIOS URL appears in UI strings

## 4. Version choice

- [x] 4.1 Settings > Consoles version picker; fallback to `-L` for builds without MCP; UI test for the "Needs the included RetroArch" label

## 5. Acceptance

- [ ] 5.1 Evidence per scenario; THIRD-PARTY-LICENSES with RetroArch and source offer by the docs agent; `openspec validate p12-retroarch-bundle --strict` passes
