# 0005. No server: a nightly compatibility JSON built by CI

One accepted decision for Cartouche. Read by contributors who need to know why.

## Status

Accepted, 2026-10-19.

## Context

Community data comes from MacGamingDB, AppleGamingWiki, ProtonDB (a 70 MB monthly ODbL export) and AreWeAntiCheatYet. Each Mac cannot fetch all of it. The project has no budget for a server.

## Decision

A nightly GitHub Actions workflow builds one gzip JSON file keyed by Steam App ID, validated against a published schema, and publishes it as a release asset under 25 MB. The app downloads it at most once a day, keeps the last valid copy and works offline. Raw MacGamingDB report rows are kept so the per-Mac estimate runs on the user's Mac. If a source fails, its previous records stay with their old date. The same channel carries the runner manifest, so new builds can be pinned without an app update.

## Alternatives rejected

- A hosted API. Rejected: cost and uptime.
- Each app fetches every source. Rejected: 70 MB per user and source rate limits.
- Precomputed estimates. Rejected: they cannot follow a different Mac.
- All of Steam in the file. Rejected: size. The file covers top Steam games plus every game in MacGamingDB or AppleGamingWiki.

## Consequences

- Data is at most a day old, and the app shows its age when older than 3 days.
- Source licenses (CC BY-NC-SA 3.0, ODbL, MIT) must be shown in the app. Derived ODbL data must be shared under the same license.
- A source that changes format fails the job and the previous file stays live.
- Fetching is polite: a User-Agent naming the project, caching and backoff.
