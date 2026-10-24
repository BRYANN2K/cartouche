# Tasks

## 1. Baseline

- [x] 1.1 Record the P0 baseline: test counts per suite and the Steam tool list; save in evidence.md

## 2. Model

- [x] 2.1 Introduce the runner model (kind, version, flavors, state, reason) with unit tests for state transitions
- [x] 2.2 Implement the registry and route every reader (status view, prefixes, Steam tools) through it; verify with a grep that no feature reads CrossOverSource directly

## 3. CrossOver on the model

- [x] 3.1 Port discovery, clone and patch steps to the model; existing CrossOver tests pass unchanged
- [x] 3.2 Add the unsupported-build test (fixture with unknown hashes) and the damaged-runner test (flipped byte)

## 4. Acceptance

- [x] 4.1 Compare test counts and Steam tool list against the baseline; record the diff (must be empty) and fill evidence.md per scenario; `openspec validate p1-runner-model --strict` passes
