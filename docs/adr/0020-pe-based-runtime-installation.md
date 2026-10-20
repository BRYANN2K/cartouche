# 0020. PE-based runtime installation

## Status

Accepted, 2026-10-20. 

## Context

Running every redistributable found in a game folder can install unnecessary components or stall setup.

## Decision

Read the game’s PE imports to choose needed runtimes such as Visual C++ and DirectX. Run one winetricks verb at a time, with a bounded timeout and a Skip button. Cover .NET with Wine Mono instead of automatically adding Microsoft .NET. Keep failures visible and let the user proceed after skipping.

## Alternatives rejected

Do not run the game’s bundled runtime installers. Do not run a batch of unrelated winetricks verbs without a way to skip a stalled step.

## Consequences

Planned. Main currently discovers redistributables from files and submits their verbs together. Exact timeout values remain an implementation choice; no new fixed value is set here.
