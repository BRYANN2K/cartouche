# 0018. Local game import and safe removal

## Status

Accepted, 2026-10-20. 

## Context

Users already have installed Windows games on local folders or external SSDs. Import is not installation, and library removal must not delete their files.

## Decision

Use an already-installed game in place by default; offer copying it into Cartouche storage. Keep a separate Cartouche prefix and record. Removing an in-place import removes only that prefix and record, never its source files.

For games installed into Cartouche-managed storage, uninstall moves the managed game to the Trash. Offer to copy save files out first with “Keep save files”. Never infer ownership of an arbitrary external folder.

## Alternatives rejected

Do not run an installed game as though it were a setup program. Do not recursively delete a user-selected source folder.

## Consequences

In-place and copy imports are merged. The Trash-based game uninstall and optional save copy are planned. This is separate from Remove Cartouche, which already preserves games, prefixes, saves and BIOS files.
