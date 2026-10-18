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

This is a short summary. The MCP threat model will be written in full when the MCP server lands (P11).

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

### MCP server for agents

- The server is local only. The default transport is stdio, started by the client.
- The optional HTTP transport listens on 127.0.0.1 only, is off by default and needs a token. Requests without it get HTTP 401.
- Three access levels: Read only, Standard (default) and Full. Tools above the level are refused.
- Installing, deleting and running an executable need the user's approval in the app.
- Tools never return store tokens, passwords, Keychain items or files outside the app folder and folders the user granted.
- Every agent action is logged in Settings > Agents.

### Other

- Store sign-in uses each store's own web page. Cartouche stores only tokens, in the Keychain.
- Compatibility data and installer metadata come from outside. The app validates the data against a schema and discards invalid files.
- Installer analysis never executes files from the dropped folder.
- FPS data stays on the Mac unless the user turns on sharing.

## Out of scope

- Vulnerabilities in Steam, Wine, games or third-party emulator cores. Report them to their projects.
- Anything that needs a modified or malicious game the user chose to run.
