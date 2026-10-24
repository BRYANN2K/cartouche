# Proposal

## Why

Fixing a game that won't start or tuning it for FPS means reading logs and trying setups. An agent (Claude or any MCP client) can do that loop for the user if Cartouche exposes safe, well-scoped tools.

## What Changes

- An MCP server (stdio helper `cartouche-mcp`, optional localhost HTTP with a token) using the official Swift SDK.
- Tools from `mockup/MCP.md`: library, install (store and Windows installer, with retry fixes), game config, FPS boost suggestions and benchmarks, runners, launch, logs, diagnose, compatibility, system.
- Three access levels (Read only, Standard, Full) and in-app confirmation for anything that installs, deletes or runs an exe.
- An action log with Undo where possible.
- Non-goals: remote access from another machine; acting on store accounts beyond what the user signed in to.
- Console tools and controls tools (see `mockup/MCP.md`) are added through the same server once P13 and P15 land; their requirements are in this change.
- Depends on P5, P6 and P8 for PC tools; P13 and P15 for console and controls tools.

## Capabilities

### New Capabilities
- `agent-control`: what agents can see and do through MCP, and how the user stays in control.

### Modified Capabilities
- None.

## Impact

New helper target, a local Unix socket between helper and app, Settings > Agents, SECURITY doc with a threat model.
