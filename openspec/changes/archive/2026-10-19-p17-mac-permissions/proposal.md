# Proposal

## Why

Cartouche touches many protected parts of macOS: it modifies Steam, reads game folders and Downloads, sends notifications, posts input events, talks on the local network. Each one triggers a macOS permission prompt. Asked all at once, or without context, users deny them and features silently break. With free signing, permissions must also survive updates.

## What Changes

- One permissions module in the app: knows every permission, its current state, why it is needed, which feature needs it, and how to recover.
- Just-in-time requests: a short Cartouche explanation sheet first, then the macOS prompt, only when the feature is used.
- Settings > Privacy lists every permission with its state and an "Open System Settings" button to the exact pane.
- Features degrade with a clear message when a permission is denied, never silently.
- Non-goals: Full Disk Access (not needed); any permission no feature uses.
- Depends on P0. Stable signing across updates comes from P9.

## Capabilities

### New Capabilities
- `mac-permissions`: which macOS permissions Cartouche asks for, when, how it explains them, and what happens when they are denied.

### Modified Capabilities
- None.

## Impact

A `Permissions/` module in the app, Info.plist usage descriptions, Settings > Privacy, reuse of NotProton's App Management handling (`WriteRefused.swift`) and Steam event access (`dylib/feats/input_access.c`).
