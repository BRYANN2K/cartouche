# Contributing to Cartouche

How to work on Cartouche: how changes are planned, what a pull request needs, and how to report a compatibility problem. Read by contributors.

Cartouche is an independent fork of NotProton, licensed GPL-3.0. It keeps NotProton's code and credits its authors. It is not affiliated with NotProton, Valve, Apple or CodeWeavers. It does not send pull requests to NotProton.

## How work is organized

- Requirements live in `openspec/specs/<capability>/spec.md`, in OpenSpec format.
- Propose a change as an OpenSpec change (proposal, spec deltas, tasks) in your branch. Once merged, its specs are folded into `openspec/specs/`. Every requirement has at least one scenario. Scenarios are the acceptance criteria.
- Read `docs/PRD.md` and `docs/TRD.md` first. Decisions are in `docs/adr/`.
- Open an issue or a discussion before a large change. Do not start code for something that has no spec.

## Branches

- `main` holds stable releases and `beta` holds betas. Open pull requests against `beta`; never commit to `main` or `beta` directly.
- Name your branch after what it does: `feat/<topic>`, `fix/<topic>`, `docs/<topic>` or `ci/<topic>`.
- Checks run on Woodpecker (`.woodpecker/`) for every pull request. See `docs/RELEASE.md`.
- Write commit messages in the imperative, one idea per commit.

## Tests and evidence

- Run the full test suite before you ask for review. Do not delete or skip a test to make it pass.
- Run `openspec validate --all --strict` when you touch `openspec/`.
- For each scenario in your change, list in the pull request the check (a test name, a command or a screenshot) and the observed result.
- Evidence must show the THEN of the scenario. A claim without a test, output or screenshot does not count.
- UI changes need screenshots in light and dark, on macOS 15 and 26, with Reduce Motion checked.
- Work that needs a real Mac or a real game is tested by the maintainer. Write the steps for them.

## Code comments

- Keep comments short.
- Add a comment only where the logic is hard.
- A comment should help a human understand the hard part. If it needs knowledge the file does not give, rewrite it.
- Write comments by hand. Shorter is better than longer, and clarity is the goal.
- Tests may be commented as you like.

## Pull requests

- Write the description yourself, in plain words. Translation is fine.
- Say which scenarios the change covers and link its evidence.
- Keep the change to one purpose. Every changed file should be explained by it.
- Touching code that runs inside Steam (`dylib/`, `lsteamclient/`, `steam-shim/`) needs extra care. Think about several Steam accounts, libraries, macOS users and file systems. Say how you tested it.
- Do not add a D3DMetal or Game Porting Toolkit file, a secret, or piracy wording in code, strings or docs. Review will reject them.

## Legal line

- Cartouche runs software the user already owns.
- No DRM circumvention. No cracks, no Steam emulators, no detection of pirated releases.
- No piracy-specific features or wording. The installer feature is called "Install from a Windows installer".
- No links to ROM, BIOS or game download sites. Missing BIOS files are reported by name only.
- Never add D3DMetal or Game Porting Toolkit files to the repository or a release.
- Anti-cheat is shown as Linux data, never as a Mac verdict.

## How to report a compatibility problem

Open an issue with these facts:

1. The game name and its Steam App ID, or the store it comes from.
2. Your Mac: chip, RAM, macOS version.
3. The setup: runner, graphics backend, Rosetta or FEX, and any environment variables.
4. What you expected and what happened.
5. The log: Game panel > Show Log, or the files in `~/Library/Logs/Cartouche`. Remove personal paths if you like.
6. For an installer problem: the installer type shown in the analysis step and the install log. Do not attach game files.

If the game works with another setup, say which one. Do not report anti-cheat results as Mac facts unless you tested them on a Mac.

## Security

Report vulnerabilities privately. See `SECURITY.md`.

## Conduct

Be kind and direct. See `CODE_OF_CONDUCT.md`.

## Credit

Cartouche derives from NotProton. Thank you to its author and contributors. See `NOTICE` for the full licensing situation.
