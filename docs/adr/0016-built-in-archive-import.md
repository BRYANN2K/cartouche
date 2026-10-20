# 0016. Built-in archive import

## Status

Accepted, 2026-10-20. 

## Context

Users should not need a separate extraction app before adding their own game files.

## Decision

Bundle an open-source decompressor for zip, rar and 7z. Use the same archive layer for installers, installed-game folders and ROMs. A dropped archive, folder, installer or ROM is classified before the matching import flow starts. Analysis must not execute dropped programs.

## Alternatives rejected

Do not ask users to install a separate decompressor. Do not give each library section its own archive implementation.

## Consequences

Planned. The library, installer and console flows need a shared classification and extraction contract. The dependency, pin and license still need selection; this ADR does not approve a particular library.
