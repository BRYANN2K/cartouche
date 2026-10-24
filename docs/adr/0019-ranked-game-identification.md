# 0019. Ranked game identification

## Status

Accepted, 2026-10-20. 

## Context

Executable and folder names are often generic. Stable local identifiers should take priority over an online name search.

## Decision

Identify games in this order: store IDs (steam_appid, GOG, Epic); engine metadata (Unity, Unreal, Godot and others); executable version information; executable name; folder names. Preserve user correction. Use Steam store search only as fallback and only when the online-lookups privacy choice permits it.

## Alternatives rejected

Do not start with a folder-name search. Do not send names online when local metadata can identify the game or online lookups are disabled.

## Consequences

Planned. Current installer matching does not yet implement this full order. Store search may disclose a game title and the user’s IP address. The privacy gate must apply to every automatic fallback request.
