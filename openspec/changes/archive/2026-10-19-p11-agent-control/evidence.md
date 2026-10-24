# Evidence — p11-agent-control

Checks run in the worktree sandbox (`swift test --no-parallel`, fixtures, no
real ~/Library, Steam or RetroArch). Backend tests live in
`app/Tests/NotProtonAppTests/AgentTests.swift` (24 tests, all passing);
controls tools in `AgentControlsTests.swift` (9 tests, all passing); the
Settings > Agents pane and approval sheet in `AgentSettingsUITests.swift`
(7 tests; the 5 that read drawn text hit the sandbox's UIHost `.nilError`
like every other UI test, the two that drive the model pass).

## Connectable server

### Claude Code connects
- How: `cartouche-mcp` executable target (`app/Sources/CartoucheMCPHelper/main.swift`)
  reads line-delimited JSON-RPC on stdin and forwards each frame over a Unix
  socket (`~/Library/Application Support/Cartouche/agent/mcp.sock`, folder
  0700, socket 0600, unlinked before bind and on quit) to the app's
  `AgentHandling`. A plain app cannot vend a Mach service, so XPC was
  replaced: `MCPSocketServer` binds the socket and admits a peer only when
  `getpeereid` reports this user's uid and the peer's executable
  (`LOCAL_PEERPID` + `proc_pidpath`, normalized) is the bundled
  `Contents/Helpers/cartouche-mcp`. If the app does not answer the helper
  opens it with `/usr/bin/open -b dev.bryann2k.cartouche` and retries, and
  answers a JSON-RPC error with the request's own id when still unreachable.
  `MCPServer` implements `initialize`, `ping`, `tools/list`, `tools/call`,
  `resources/list`, `resources/read`, notifications (no reply) and ordered
  batches on protocol `2025-06-18`.
- Checked by: `MCP protocol` suite — initialize version/server name,
  tools/list metadata, tools/call routing, unknown-method -32601, notification
  silence, batch order, invalid params -32602, `MCPUnreachable` replies carry
  the request id — and `MCP socket transport`: request/reply over a served
  connection, the peer check admitting this user's own executable and refusing
  another path, a non-socket fd failing, a refused peer closed without reply,
  a missing socket answering unreachable, socket-path agreement between app
  and helper. All run in the sandbox except the three that need a real `bind`
  (round-trip, 0700/0600 permissions, unlink on stop), which skip there and
  run on unsandboxed machines.
- Note: the hand-rolled transport mirrors `RetroArchKit.MCPClient` (the
  official Swift MCP SDK is not a dependency). An interactive MCP-inspector
  session was not run inside the sandbox.

### HTTP is local only
- How: `MCPHTTPServer` builds `NWParameters.tcp` with
  `requiredInterfaceType = .loopback`, accepts `POST /mcp` only, and requires
  `Authorization: Bearer <token>`; `AgentControlModel` generates the token
  once, keeps HTTP off by default and binds port 3398.
- Checked by: `HTTP MCP transport` — `parameters()` is `.loopback`; a live
  listener returns `401` for a wrong and a missing token, `200` with the
  handler's bytes for the right one. Passes.

## Access levels and confirmation

### Refused above level
- How: `AgentService.call` checks `tool.level <= level` before anything runs
  and records a `.refused` action. Levels: `readOnly` < `standard` < `full`.
- Checked by: `read-only level refuses action tools` — `set_favorite` at
  read-only is refused with "needs standard access" and `list_games` still
  answers; `standard level refuses full tools` — `run_winetricks` refused.
  Passes.

### Install needs approval
- How: tools flagged `approval: true` suspend in `AgentService.ask` until
  `answer(id, allow:)`, a timeout (default 5 min, denies), and post a
  notification through `AgentNotifier` (UNUserNotificationCenter, Allow/Deny
  actions routed via `AgentNotifier.onAnswer`). The in-app half is
  `AgentApprovalSheet`, presented by `.agentApprovals(model)` on the main
  window and mirrored as a "Waiting for You" row in Settings > Agents —
  both ask "<client> wants to <text>. Allow?" with Deny and Allow.
- Checked by: `a risky tool waits for the approval; allow runs it`,
  `deny records a denied action`, `approval timeout denies on its own` —
  pending approval is observable, allow runs, deny/timeout answer isError.
  Passes. UI level: `AgentApprovalUITests` renders the sheet ("wants to …
  Allow?", Deny and Allow buttons) and answers the suspended call through
  the model — the Allow test passes; the OCR-dependent assertions hit the
  sandbox's `.nilError` like every UIHost test, and `pendingRow` proves the
  Settings row path through the model.

## Useful repair loop

### Diagnose and fix a crash
- How: `AgentDiagnose.diagnose` parses the launch/wine log for missing-DLL,
  decompressor, nonzero-exit and anti-cheat patterns and returns fixes as
  `{tool, args, why}` proposals.
- Checked by: `a missing-DLL log names the DLL and a winetricks fix` —
  `vcruntime140.dll` is named and `run_winetricks` proposed. Passes.

### Retry an install
- How: `retry_install` accepts `fix` including `single_thread`
  (`applyThreads`) and the diagnose fixture maps `unarc.dll returned an error
  code` to retry proposals.
- Checked by: `a decompressor failure proposes the retry fixes` — two
  `retry_install` fixes from an unarc -11 line. Passes. (The live
  one-thread run is `InstallCenter` behavior already covered by installer
  tests.)

## Accountability

### Undo a config change
- How: `AgentService.snapshotUndo` captures setup/favorite/hidden/default
  runner/console-setup state before the tool runs; `undo(id)` restores it,
  marks the entry `undone`; history persists to
  `agents/actions.jsonl` under the support folder. Controls mutations
  (`set_controls`, `set_keyboard_mouse`, `set_controller_for_keyboard_game`)
  snapshot the game's whole `GameControls` the same way.
- Checked by: `undo restores the setup the action changed` — runner-after is
  applied, undo restores runner-before, log records the undo. Passes. And
  `a controls change is undone from the action log` — a layout change made
  through `set_controls` is reverted by `service.undo`. Passes.

### The action log the user sees (task 3.1)
- How: `AgentsSettingsView` (`AgentViews.swift`) binds to
  `AgentControlModel` — enable toggle, Read Only/Standard/Full picker with
  the level's explanation, pending approvals with Deny/Allow, the Claude
  Code command, the HTTP toggle with loopback URL, bearer token and the
  client configuration snippet behind Copy buttons, and "Recent Agent
  Actions" (client · args · time · outcome) with Undo where `canUndo`.
  It is the `.agents` case of `SettingsTab`, reached through the
  `AgentControlModel` environment in `SettingsWindow`.
- Checked by: `Settings > Agents` suite — pane rows render, HTTP on shows
  URL/token/client configuration (`model.clientConfiguration` asserted
  verbatim for both forms), the level picker writes the service and
  defaults, the log lists a recorded action with its client and Undo
  (`model.undo` restores the favorite), a pending approval answers from the
  pane. The 4 OCR-dependent assertions hit the sandbox's UIHost
  `.nilError`; `level` and `log`'s model-level parts pass. `Each tab
  renders in light and dark` now includes the Agents pane (all panes share
  the sandbox window-size limit).

## No secrets exposed

### Secret scan
- How: every tool reply and resource passes `AgentScan.scrub` — token patterns
  (JWTs, key=value secrets, private keys, `sk-`, `ghp_`) become `[redacted]`,
  allowed roots shorten to `~/…`, outside paths collapse to `…/<name>`; file
  arguments must sit inside `roots.allowed` (`isAllowed`).
- Checked by: `a planted token and a home path are scrubbed out of every
  answer` (a `sk-…` token and a home path planted in a served log never reach
  the wire) and `outside-root paths keep only their file name`. Passes.

## One server for every kind of game

### Console games are listed
- How: `list_games` returns console entries alongside PC games and console
  tools (`list_consoles`, `list_states`, `launch_console_game`, `save_state`,
  `console_screenshot`, `swap_disc`, …) run through `AgentBackend` →
  `ConsoleCenter` → `ConsolePlayer` (RetroArchKit).
- Checked by: the read-tool contract test serves `list_consoles` and
  `list_states` on a console fixture; the fixture backend records console
  calls for action tests. Passes.

### No direct RetroArch access
- How: no RetroArch endpoint is exposed — the agent surface is
  `CartoucheMCP`'s stdio/socket/HTTP only, and every console tool relays
  through `AgentBackend`, which owns the RetroArchKit session.
- Checked by: code review — `AgentBackend` is the single path; nothing in the
  agent tools opens RetroArch's `--mcp-stdio` channel itself.

### Hardcore is protected
- How: `AgentService.call` refuses `sendsInput` tools when the playing console
  game's `setup.hardcore` is true, before the backend runs.
- Checked by: `sendsInput tools are refused while a Hardcore console game
  runs` — `save_state` refused naming Hardcore, backend untouched. Passes.

### Controls tools (P15, same server)
- How: `AgentControls` (`AgentControls.swift`) is an `AgentToolProvider`
  registered in `CartoucheApp.init` — `list_controllers` (read-only),
  `get_controls` (read-only), `set_controls`, `set_keyboard_mouse` and
  `set_controller_for_keyboard_game` (Standard). All read and write through
  `ControlsCenter`, so Wine games get SDL mappings, console games get
  RetroArch remaps, Steam games are refused with a Steam Input pointer and
  Play-with-a-controller refuses unless macOS already granted Cartouche
  Accessibility (the app asks; the agent only reads the state).
- Checked by: `Agent controls tools` suite (9 tests, all pass) — pads
  listed with family/battery, handler reported per game kind, preset and
  button swaps persisted, Steam refused, console refused for keyboard
  options, Accessibility refusal names the app's permission, undo restores
  the previous layout, read-only level refuses.

## Verification summary

- `swift test` (app, sandbox): 24 Agent/MCP backend tests, 9 controls-tool
  tests, 6 socket-transport tests and the service-level parts of the UI tests
  pass. The remaining failures are the known environmental ones (no staged
  payload, no keychain, no RetroArch dmg, sandboxed ~/Library, window
  geometry, and every UIHost render/OCR test returning `.nilError` — my 5
  pane/sheet read-backs fail the same way as the pre-existing
  BIOS/Covers/Controls UI tests) — nothing in the agent files' logic. The 3
  socket tests that need a real `bind` skip under the CLI sandbox (it denies
  AF_UNIX binds even in the workspace) and run elsewhere.
- `swift test` (retroarch): 2 known fixture failures (missing
  `RetroArch_Metal.dmg`), same as baseline.
- `swift test` (installer): 73/73 pass.
- `make -s packagingcheck`: redist-scan and workflow-check pass; signing-test
  and the appcast unittest fail inside the sandbox (no keychain creation,
  `SPARKLE_PRIVATE_KEY` unset) — rerun outside the sandbox.
- `openspec validate p11-agent-control --strict`: passes.
- `make app` / `l10ncheck`: not run in the sandbox; 24 more localized keys
  (Agents pane, approval sheet, Undo/Undone/Denied/Refused/Failed, the
  access-level footer and the connect rows) were added to
  `Localizable.xcstrings` with zh-Hans and it translations in catalog
  order, on top of the six keys the backend run added (Allow, Deny,
  Cartouche agent request, Read Only, Standard, Full).
- SECURITY: `SECURITY.md` exists from P0; its MCP threat-model section is
  explicitly deferred to the docs agent ("written in full when the MCP
  server lands (P11)") and is not part of this change's diff.
- An interactive MCP-inspector session was not run inside the sandbox.
