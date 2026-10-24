# How Cartouche is built: orchestrator and subagents

For the maintainer and for agents working on the repo. It says who does what for each phase in `docs/ROADMAP.md`, and when a phase counts as done.

## Roles

| Role | Who | Model, effort | Does | Never does |
|---|---|---|---|---|
| Orchestrator, lead and reviewer | Main Claude session | Opus, high | Opens and orders phases, writes and fixes specs with the user, dispatches subagents, reviews every phase, merges, archives | Merges without evidence |
| Implementer | `cartouche-implementer` | Opus, high | Codes one change on `phase/<id>`, tests, fills evidence.md | Edits specs, touches another phase's files |
| Frontend | `ui-gate` | Sol 6.1 | Builds UI and, after every merged change, checks UI coverage and builds missing UI | Assumes a backend merge proves the UI is complete |
| Researcher | GPT-6 Luna | – | Answers one factual question with sources in `docs/research/`; browses the web through Aside | Writes code |
| Docs and translations | Devin | – | Writes and updates the documents below after each phase; produces the it, zh-Hans and fr strings | Invents behavior |
| Maintainer | You | – | Approves specs before a phase starts, tests on real hardware when evidence needs it, approves releases | – |

Definitions are in `.claude/agents/`.

## Loop for one phase

1. **Ready.** The orchestrator checks the change with the maintainer: open questions answered, specs approved. `openspec validate <id> --strict` passes.
2. **Research (if needed).** Each open question goes to the researcher (GPT-6 Luna, through Aside). Answers land in `docs/research/` before coding starts.
3. **Build.** `cartouche-implementer` works in its own worktree on `phase/<id>`, task by task.
4. **Docs.** Devin updates the documents owned by the phase (table below) on the same branch.
5. **Review.** The orchestrator runs the review checklist. Any failure goes back to step 3 with a precise list.
6. **Merge.** Merge the reviewed change to main.
7. **UI follow-up after every merge.** The orchestrator sends the merged change to the frontend agent `ui-gate` (Sol 6.1), including backend-only changes. The agent verifies that the UI covers the change and builds any missing UI. It reports what was checked, any UI added, and remaining blockers. Do not treat a backend merge as proof of UI completion. Repeat this check after follow-up changes are merged too.
8. **Archive.** Once required evidence and UI follow-up are complete, `openspec archive <id>` moves the accepted specs into `openspec/specs/`.

Phases of the same wave run at the same time only when they touch different directories.

## Review checklist (all must pass)

- Every scenario in the change's specs has an entry in `evidence.md`, and the evidence actually shows the THEN (output, test name, screenshot).
- Full test suite green on CI, no test removed or skipped.
- `openspec validate --all --strict` passes.
- `/code-review` on the branch diff: no correctness finding left open.
- No scope creep: every changed file is explained by a task.
- No D3DMetal or GPTK file, no secret, no piracy wording in code, strings or docs.
- UI phases: screenshots in light and dark, macOS 15 and 26, Reduce Motion checked, anti-slop rules respected.
- Docs owned by the phase are updated and consistent with the code.

## Evidence format

`openspec/changes/<id>/evidence.md`, one block per scenario:

```
### <Requirement> / <Scenario>
- Check: test `RunnerTests.testDamagedRunnerIsCaught` | command `…` | screenshot `evidence/…png`
- Result: pass, <the observed value>
```

Evidence that needs real hardware or a real game is done by the maintainer; the orchestrator writes the steps.

## Documents and when they are written

| Document | Path | Phase |
|---|---|---|
| PRD (product requirements) | `docs/PRD.md` | P0 |
| TRD (technical requirements and architecture) | `docs/TRD.md` | P0, updated each phase |
| ADRs | `docs/adr/` | Any phase with a decision (first ones: name, free signing, no server, macOS 15, OpenSpec) |
| README, NOTICE, CONTRIBUTING, CODE_OF_CONDUCT | root | P0 |
| GLOSSARY (runner, backend, prefix, setup…) | `docs/GLOSSARY.md` | P1 |
| French glossary (vouvoiement, Apple terminology) | `docs/l10n/glossary-fr.md` | – |
| TESTING | `docs/TESTING.md` | P1 |
| THIRD-PARTY-LICENSES | root | P2, P3, P6, P10 |
| DATA-SCHEMA (compat JSON, local stores) | `docs/DATA-SCHEMA.md` | P4, P8 |
| PRIVACY | `docs/PRIVACY.md` | P4, P8, P11 |
| APPFLOW (screens and transitions) | `docs/APPFLOW.md` | P5 |
| DESIGN (UI rules, anti-slop, Liquid Glass) | `docs/DESIGN.md` | P5 |
| TROUBLESHOOTING | `docs/TROUBLESHOOTING.md` | P6 |
| RELEASE, CHANGELOG | `docs/RELEASE.md`, root | P9 |
| SECURITY (with MCP threat model) | root | P0, P11 |

## Communication

- The orchestrator talks to the maintainer in French, short and with a recommendation. Code, specs and docs are in English.
- A subagent blocked by a spec problem stops and reports; it does not guess.
- One phase at a time per set of files. Two writers never touch the same files.
- Every agent ends its final report with the fixed reply format below; nothing comes after it.

## Reply format

```
status: done | blocked
branch: <branch> (uncommitted ok)
files: A.swift, B.swift, …
tests: <what ran> → <result>; env-only failures: <count/kind>
orchestrator: <commands to run outside the sandbox, or none>
open: <points to review, or none>
```

## QA scheduling (2026-10-21)

QA persona runs are postponed by the maintainer. Do not schedule them until resumed, mark them passed, or replace missing persona evidence with source review. Other approved tests and the post-merge ui-gate process remain in force.
