# Merged local-game follow-ups

Status: implemented in main 307ad2c on 2026-10-20. ADRs 0018–0021 apply. This contract reconciles the merged batch with the canonical specs; it does not claim pending Steam export writing is done.

## Changes

Ranked local identification, one privacy-gated Steam lookup path for identification and cover fallback, PE-import runtime selection with one verb per step/timeout/Skip, managed-game Trash uninstall with optional prefix-save copy, safe in-place removal, and closed-Steam use of the last account-matched export at any age with a stale label. localconfig.vdf is play data only.

## Remaining work

The Steam-side export writer remains in progress under steam-export. Archives, direct-unpacker app integration and CrossOver default/first boot remain separate changes. Epic-specific local identity coverage is not proven by this merge.
