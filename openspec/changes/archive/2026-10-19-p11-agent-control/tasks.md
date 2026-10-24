# Tasks

## 1. Server

- [x] 1.1 Helper target with the Swift MCP SDK over stdio, local socket to the app; test with the MCP inspector
- [x] 1.2 Optional HTTP transport on 127.0.0.1 with token; tests for 401 and binding

## 2. Tools

- [x] 2.1 Read tools (library, game, logs, compatibility, system); contract tests
- [x] 2.2 Action tools (install, config, launch, retry, runners, winetricks) behind levels; tests for refusals
- [x] 2.3 Approval flow with notifications; UI test for Allow and Deny
- [x] 2.4 diagnose and suggest_fps_boost on recorded crash and session fixtures; tests

## 3. Control

- [x] 3.1 Settings > Agents, action log, Undo; UI tests
- [x] 3.2 Secret and path scan over every read tool; CI test

## 4. Acceptance

- [x] 4.1 Evidence per scenario; SECURITY doc with threat model by the docs agent; `openspec validate p11-agent-control --strict` passes
