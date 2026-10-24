# Onboarding v2

Status: approved 2026-10-21; implementation pending. ADR 0032.

## Why

The five-step flow predates store integrations, controller support and the Cartouche Wine default. Setup now spans more areas, and downloads started in a step made onboarding wait on them.

## What Changes

- Seven steps, each skippable: Welcome with the detection scan, Windows games (Cartouche Wine preselected as the default runner, with a way to pick the user's own Game Porting Toolkit disk image), Stores, Consoles, Controller, Permissions, storage and privacy, Ready.
- Downloads and installs started during onboarding run as background tasks; steps do not block on them.
- Onboarding saves the step and choices after each step and resumes on the saved step after a relaunch.
- Non-goals: new permission kinds, changes to what Settings offers, a feature tour.
- Supersedes the five-step flow of the p18-onboarding change.

## Capabilities

### New Capabilities
- None.

### Modified Capabilities
- `onboarding`: the first-launch step list, background tasks and relaunch resume.

## Impact

Onboarding UI in the app, `mockup/onboarding.html`, `Localizable.xcstrings` (en, it, zh-Hans, fr), the onboarding spec.
