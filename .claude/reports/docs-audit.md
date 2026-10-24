# Documentation audit — 2026-10-20

Compared docs with main at aee76d1, the commit history, FORK-PLAN.md, .claude/night-report.md, phase evidence/specs, and local Wine reports. No code was edited.

## Stale or wrong

- TRD, PRIVACY and README still called P11 an unmerged proposal. P11 is merged and archived.
- TRD linked P5 and P14 to removed active-change folders. Both are archived. P10 remains active.
- P5 archival does not mean the full Steam export exists: its evidence still marks the writer missing. The importer only consumes an export if present and merges appmanifests and play data.
- Runner docs described the old in-app build workflow rather than public BRYANN2K/cartouche-wine publication. App sources stay private until v0.1.0.
- The PRD's 60-second cold winecfg goal conflicts with observed prefix initialization. system.reg and .update-timestamp are not completion proof. Local repair took 670.94 seconds; this is not a fixed delay or benchmark.
- Local-game import, direct unpacker plans, decompression, identification, runtime steps and game-removal ownership rules had no architectural records.
- TRD still called the daily-check off switch undecided and omitted signature verification in its runner-manifest table.
- FORK-PLAN.md is an older French plan, says nothing is coded, and has superseded signing/phase details. It was read but not edited: outside the assigned documentation paths. The night report is historical, not a current status source.

## Changed

- Added ADRs 0015–0021 and indexed them: Wine publication/default/boot, shared archive import, installers with external unpackers, safe local-game lifecycle, ranked identification, PE runtime setup, and closed-Steam library rules.
- Updated PRD, TRD, ROADMAP, PRIVACY, RELEASE, README and CHANGELOG. Preserved merged-versus-planned distinctions and linked the landing page. Added a portable Wine first-boot research summary under docs/research/.
- Kept v0.1.1 opt-in statistics and the public website game list with user stars explicit. No unapproved report endpoint or field list is invented.

## Open questions / work not claimed done

- Select and pin the open-source decompressor and confirm its license.
- Finish direct extraction format support. Main still runs setup after unpacker preparation.
- Finish the serialized prefix-completion gate and default-runner selection. Existing WineBootstrap is insufficient.
- Implement the full ranked identifier and its online-lookups gate; PE-based runtime selection, one verb per step, timeout and Skip; managed uninstall to Trash with optional save copy.
- Finish the Steam-side full-library export writer and confirm cached/stale presentation on real Steam.
- Decide v0.1.1 submission/storage/hosting and exact shared fields before enabling the website features. No v0.1.0 app backend is implied.
- Existing phase evidence retains real-game, real-service, signed-update and clean-account manual checks. This audit did not run those checks.

Validation: local Markdown links in changed files resolve; git diff --check passed. Existing accepted ADRs 0001–0014 were left unchanged.
