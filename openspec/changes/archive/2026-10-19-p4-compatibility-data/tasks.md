# Tasks

## 1. Schema and fixtures

- [x] 1.1 Write `docs/schema/compat.schema.json`; validate the 2026-10-18 fixtures against it
- [x] 1.2 Record fixtures for Elden Ring, Apex Legends, Counter-Strike 2 and Disco Elysium from each source

## 2. Builder and workflow

- [x] 2.1 Builder fetching each source with caching and backoff; unit tests against fixtures
- [ ] 2.2 Nightly workflow publishing the gzip file; verify size, schema and date on a manual run
- [x] 2.3 Failure path: simulate one source down; verify previous records are kept and marked
- [x] 2.4 Remove MacGamingDB from the builder, the schema and the file; a test and the publish check scan the file for any MacGamingDB field or value

## 3. Client

- [x] 3.1 Daily fetch, cache, schema check, age display; tests for offline, corrupt and stale cases
- [x] 3.2 Estimate function; test the M4 Elden Ring fixture result and the no-report case
- [x] 3.3 Anti-cheat and attribution strings; review against the wording scenario
- [x] 3.4 MacGamingDB client in the app: on demand, per-game cache refreshed at most once a day, at most two requests at a time; tests with the recorded Elden Ring answer for the first open, the second open and offline
- [x] 3.5 "Fetch Mac reports from MacGamingDB" in Settings > Privacy, on by default; test that off sends no request and the estimate area says reports are turned off
- [x] 3.6 Estimate and panel read MacGamingDB from the live cache; the M4 Elden Ring and no-report tests still pass

## 4. Acceptance

- [ ] 4.1 Evidence per scenario; DATA-SCHEMA and PRIVACY written by the docs agent; `openspec validate p4-compatibility-data --strict` passes
