# Separate Wine CI boot phases

Maintainer decision: 2026-10-20. Implementation: cartouche-wine/wine-build commit eb1ae1f. CI run 39498286344 started; result pending.

## Why

Fresh prefix initialization can exceed 60 seconds without indicating a broken graphics driver. Keep the GUI deadline but measure boot initialization separately.

## What changes

CI runs wineboot -i with mscoree,mshtml= overrides (CI only), then wineserver -w, under the 20-minute BOOT_INIT_LIMIT. Log initialization time, then keep the 60-second winecfg window check. Do not apply this CI limit or these overrides as app launch policy. ADR 0015 is unchanged.
