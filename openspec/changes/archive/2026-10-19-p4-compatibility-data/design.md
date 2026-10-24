# Design

## Context

MacGamingDB has a public REST API (`/api/rest/games/{appid}`) with per-report chip, backend, rating and FPS, but publishes no data license. AppleGamingWiki blocks Cargo queries, so pages are parsed from wikitext. ProtonDB publishes a monthly ODbL export (~70 MB). AreWeAntiCheatYet publishes `games.json` (MIT).

## Goals / Non-Goals

**Goals:** one small file, rebuilt nightly, that the app can trust and read offline; MacGamingDB reports read by the app, on demand, without Cartouche redistributing them.
**Non-Goals:** real-time data; a server.

## Decisions

- **Build in CI, ship as a release asset.** Free, versioned, cacheable by GitHub's CDN. Rejected: a hosted API (cost, uptime) and client-side fetching of every source (70 MB per user, rate limits).
- **Limit to games people play.** Steam's top games, every game in AppleGamingWiki or AreWeAntiCheatYet, and every game with at least 10 ProtonDB reports in the last year. Rejected: all of Steam (size).
- **Read MacGamingDB live from the app, never put it in the file.** The app asks `/api/rest/games/{appid}` when a game's details or estimate are needed, caches the answer per game, refreshes it at most once a day, and keeps the last good copy. Rejected: redistributing MacGamingDB data in the nightly file, because MacGamingDB publishes no data license. Rejected: prefetching the whole library, which would send every owned game to MacGamingDB and load its API.
- **Privacy cost of the live read.** MacGamingDB sees which games the user opens, from the user's IP address. No account and no Mac identifier is sent beyond the HTTP request. Settings > Privacy has "Fetch Mac reports from MacGamingDB", on by default; off, no request goes to macgamingdb.app, the panel shows AppleGamingWiki only and no estimate. PRIVACY says so.
- **Keep raw MacGamingDB report rows in the Mac's cache** (chip, method, layer, rating, fps, settings) so the estimate runs on the Mac. Rejected: precomputed estimates, which cannot follow a different Mac.
- **Polite fetching:** a User-Agent naming the project, caching between runs, backoff in CI, and on the Mac at most two MacGamingDB requests at a time, one per game per day.

## Risks / Trade-offs

- [A source changes its format] → schema validation fails the job before publishing; the previous file stays live. For MacGamingDB, an answer the app cannot read is discarded and the cached copy stays in use.
- [License terms of a source change] → attribution and license list are data in the file, reviewed in the monthly upstream check (P9).
- [MacGamingDB is down or rate limits] → the cached copy per game stays in use; games never opened before show no estimate.
- [GPU strength table is a rough guess] → stored in the data file, tuned without an app update.
