# Published Cartouche Wine as default

Status: implementation merged in main 95b4e47; real-hardware checks remain pending.

## Why

The public Wine archive is now published. The app needs its pin, a default that supports the chosen graphics backends, and a first-boot gate that does not start games in incomplete prefixes.

## What changes

Pin the wine-crossover-26.3.0-1 asset in runners.json, default new games to Cartouche Wine, explain Graphics requirements (D3DMetal needs Cartouche Wine plus user-supplied GPTK files), and serialize explicit first boot before installers or games launch.

## Provenance

Release tag wine-crossover-26.3.0-1 points to fef50c2 in BRYANN2K/cartouche-wine. It reuses the archive built by run 39472948579; the build passed and only its old 60-second cold boot check failed. No rebuild was needed because later changes affected only boot checking and the publishing repository name. Size: 149444708 bytes. SHA-256: 60400817826a053599193aa290d4e24e97213a743195f4187400bf9c74906887. Publication does not prove the new boot check passed.

## Graphics UI amendment (2026-10-21)

ADR 0027 supersedes the reason-line UI: hide unavailable backends and all panel/menu reasons. Show one Get More Graphics Backends… entry only when something is missing, leading to Cartouche Wine installation. Onboarding preselects Cartouche Wine. Runtime eligibility is unchanged; this UI amendment remains pending implementation.
