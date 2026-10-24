# Security policy

How to report a vulnerability in Cartouche, which versions get fixes, and the main security risks. Read by reporters, users and contributors.

## Report a vulnerability

- Use GitHub private vulnerability reporting: open the Security tab of the repository and choose "Report a vulnerability".
- Do not open a public issue for a vulnerability.
- Include the version, your macOS version, the steps to reproduce and the impact.
- You will get an answer as soon as the maintainer can read it. Cartouche is a volunteer project and gives no response time guarantee.
- After a fix is released, the advisory is published and you are credited if you wish.

## Supported versions

Only the latest release gets security fixes. Update through Sparkle or Homebrew.

## Threat overview

This is a short summary. Agent control (P11) is specified in `openspec/specs/agent-control/spec.md`; its section below describes the transport as implemented.

### Code injected into Steam

- Cartouche injects a dylib into the Mac Steam client. This code runs with Steam's rights.
- A bug there can crash Steam or expose Steam data.
- Hooks must fail closed: if one cannot be installed, Steam still starts.
- Review of changes under `dylib/`, `lsteamclient/` and `steam-shim/` is strict.

### Downloaded runners and backends

- Wine builds, DXMT and DXVK are downloaded outside the app release.
- Each file is checked against a SHA-256 in a pinned manifest before use. A mismatch deletes the file.
- Runner files are checked again later. A changed file marks the runner damaged.
- Cartouche never downloads or hosts D3DMetal or Game Porting Toolkit files.

### Self-signed signing

- Releases are signed with a self-signed certificate, not notarized. Gatekeeper warns on the first launch.
- The stable identity lets macOS keep permissions across updates.
- The certificate private key and the Sparkle EdDSA key live only in CI secrets.
- Sparkle accepts only updates signed with Cartouche's EdDSA key. The NotProton feed is never contacted.
- Verify downloads against the SHA-256 shown in the release or the Homebrew cask.

### MCP server for agents (P11)

The MCP server lets an AI agent read the library and act on it through the same functions the UI uses. The threat is a malicious or confused agent, or a network party reaching the server.

- The default transport is stdio: a `cartouche-mcp` helper binary the client starts (`claude mcp add cartouche -- cartouche-mcp`). The helper speaks MCP over stdio to the client and reaches the app over a Unix socket at `~/Library/Application Support/Cartouche/agent/mcp.sock`. The socket's folder is 0700 and the socket 0600; the app accepts a peer only when it runs as the same user (`getpeereid`) and its executable is the bundled helper inside the app (`LOCAL_PEERPID` + `proc_pidpath`). An agent never reaches the app's internals directly.
- The optional HTTP transport listens on 127.0.0.1 only, is off by default and needs a token. Requests without it get HTTP 401. Remote access from another machine is a non-goal.
- Three access levels: Read only, Standard (default) and Full. Every tool belongs to a level; a call above the level set in Settings is refused and names the level it needs.
- Tools that install, delete or run an executable wait for approval in the app. A notification asks "Allow?" and the tool returns only after Allow or Deny.
- Every agent action is logged in Settings > Agents with the client name and time. Configuration changes can be undone from the log, and the undo is itself recorded.
- A test client scans every read tool's answers for token patterns and paths outside the allowed roots. The scan is a CI test.
- Agents reach RetroArch only through Cartouche's relay: the app starts RetroArch with `--mcp-stdio` only, so there is no RetroArch endpoint to reach. Cartouche applies its access levels before relaying, and refuses input tools while a Hardcore session runs.
- An agent can never receive store tokens, passwords, Keychain items, or files outside the app's data folder and folders the user granted. It cannot act on store accounts beyond what the user signed in to.

### Other

- Store sign-in uses each store's own web page. Cartouche stores only tokens, in the Keychain.
- Compatibility data and installer metadata come from outside. The app validates the data against a schema and discards invalid files.
- Installer analysis never executes files from the dropped folder.
- FPS data stays on the Mac unless the user turns on sharing.

## Out of scope

- Vulnerabilities in Steam, Wine, games or third-party emulator cores. Report them to their projects.
- Anything that needs a modified or malicious game the user chose to run.
