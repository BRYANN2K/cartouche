# 0006. OpenSpec and the orchestrator and subagent workflow

One accepted decision for Cartouche. Read by contributors and agents who need to know why.

## Status

Accepted, 2026-10-19.

## Context

The project is built mostly by AI agents under one maintainer. Without strict specs, agents drift and claim work is done without proof. Several phases can run in parallel only if they do not touch the same files.

## Decision

Each phase is one OpenSpec change in `openspec/changes/`, with a proposal, specs, tasks and sometimes a design. Every requirement has at least one scenario, and every THEN is observable. A phase is done when each scenario has evidence in `evidence.md`, the orchestrator review passed, and the change is archived. The main Claude session (Opus) orchestrates and reviews. Implementer agents work on the branch `phase/<change-id>` in their own worktree. Research and docs agents (Sonnet, medium effort) write in `docs/research/` and `docs/`. The maintainer approves specs and tests on real hardware. Details: `docs/ORCHESTRATION.md`.

## Alternatives rejected

- Free-form tasks and issues. Rejected: no checkable acceptance criteria.
- One agent does everything. Rejected: no independent review, no parallelism.
- Merge without evidence. Rejected: the review checklist forbids it.

## Consequences

- Specs must be approved before code starts.
- Two writers never touch the same files, so parallel phases need disjoint directories.
- Anything needing a real Mac or a real game is done by the maintainer, with steps written by the orchestrator.
- Branch naming is `phase/<change-id>`, never work on main.
