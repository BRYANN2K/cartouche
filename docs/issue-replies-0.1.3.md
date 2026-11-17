# Issue replies for Cartouche 0.1.3

Drafts only. Publish after v0.1.3 is available and its release bundle has been checked.

## #23 — RetroArchSessionError 4 when launching console games

Thanks for reporting this. I found that the public 0.1.2 package was missing the RetroArch copy Cartouche expects by default. This can cause the `RetroArchSessionError 4` you saw.

[0.1.3](https://github.com/BRYANN2K/cartouche/releases/tag/v0.1.3) includes RetroArch and checks that it is present during packaging. Launch errors also show a readable explanation instead of a generic error code, with the RetroArch log location when a session was started.

Could you update and try Chrono Trigger and Tetris again? If either still fails, please share the new error message and your selected RetroArch version from Settings > Consoles.

## #24 — Support OpenBIOS as an alternative to the official PlayStation BIOS

Thanks for reporting this. Cartouche was checking for specific Sony BIOS hashes before letting the core launch, which also rejected OpenBIOS.

[0.1.3](https://github.com/BRYANN2K/cartouche/releases/tag/v0.1.3) accepts 512 KiB OpenBIOS images with SwanStation. Put the image in Cartouche's BIOS folder; there is no need to rename it to `scph5501.bin`. An image already renamed that way is recognized too.

BIOS checks now follow the selected core. PCSX ReARMed can use its built-in BIOS, while cores that require an external BIOS still check for one. Failed BIOS checks also give more detail.

Could you try Chrono Cross again with SwanStation and your OpenBIOS image, and let me know whether it launches?
