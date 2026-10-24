# Cartouche QA report — <persona> — <date>

- **Persona**: beginner | medium | senior
- **World profiles used**: e.g. `clean`, `steam`, `broken`
- **Duration**: session length
- **Build**: Cartouche version / commit under test

## Narrative

Three to six sentences. What did you try to do, in your own words? Where did
the session go well, where did it fall apart? Stay in your persona's voice.

## Findings

Severity:

- **blocker** — a flow cannot be completed, or data/files are lost or put at risk
- **major** — a spec requirement fails, or a flow needs an unreasonable workaround
- **minor** — confusing, inconsistent or incomplete, but the goal is reached
- **polish** — cosmetic: alignment, wording, animation, feel

| ID | Severity | Screen | Steps | Expected | Actual | Screenshot | Spec |
|----|----------|--------|-------|----------|--------|------------|------|
| <persona>-01 | major | Installer | Dropped fixture folder with data-02.bin removed | Missing part named in red, Install disabled | … | shots/<persona>/setup02.png | openspec/specs/windows-installer/spec.md |

- Number findings `<persona>-NN` in the order found.
- **Steps** must be repeatable: world profile, armed mocks, click path.
- **Screenshot** is a path under `qa/reports/`; leave `—` if none.
- **Spec** is the requirement source file; write `UX gap` when no spec covers it.

## Coverage

List the scenario IDs from `qa/scenarios.md` you exercised, each with
`PASS` / `FAIL` (which becomes a finding above) / `BLOCKED` (state not
reachable — say why). Example:

`FIRST-01 PASS, FIRST-02 FAIL (→ beginner-03), LIB-03 BLOCKED (no way to remove Steam from the world)`

## What felt good

Honest positives — moments the app did something clearly right, small
delights, wording that respected you. Two to five bullets, persona voice.

## Suggestions (optional)

One-line, actionable. No redesigns.
