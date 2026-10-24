# 0032. Onboarding v2: seven steps with background tasks

## Status

Accepted, 2026-10-21. Supersedes the five-step first-launch flow of the p18-onboarding change and the onboarding spec. Implementation pending.

## Context

The five-step flow (Welcome, PC games, Consoles, Folders and privacy, Ready) was designed before store integrations, controller support and the Wine CrossOver default landed. Setup now spans more areas, and downloads started in a step made onboarding wait on them.

## Decision

Onboarding has seven steps, each skippable: Welcome with the scan of what Cartouche found, Windows games (Wine CrossOver preselected as the default runner, with a way to pick the user's own Game Porting Toolkit disk image), Stores, Consoles, Controller, Permissions, storage and privacy, and Ready. Downloads and installs started in a step run as background tasks that do not block moving on. Onboarding saves the step and choices after each step and resumes on the saved step after a relaunch.

## Alternatives rejected

- Keep five steps and fold stores and controllers into existing steps: longer steps, buried choices.
- Block a step until its downloads finish: leaves the user waiting with nothing to do.

## Consequences

The onboarding spec is amended by the `onboarding-v2` OpenSpec change. App Management is still asked only where it is needed, before modifying Steam. Every choice remains reachable from Settings. Each scenario needs evidence before the change is archived.
