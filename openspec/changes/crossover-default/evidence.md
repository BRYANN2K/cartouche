# Merged implementation evidence

Main 95b4e47 includes the published Cartouche Wine pin with real size/hash, first runner-list placement and default selection for new games when installed. Existing explicit choices remain separate from that default.

D3DMetal requires CrossOver-capable Wine, Rosetta and D3DMetal files from the user. DXMT requires CrossOver plus its download. Graphics choices explain unmet requirements; Get More Graphics Backends opens Settings > Compatibility.

WineBootstrap serializes explicit first boot with wineboot -u then wineserver -w. The UI exposes Preparing Windows environment, Show Log, Try Again and Recreate Prefix. The gate runs before direct unpack.

This documentation update records the merge and inspected source, not a new test run. Real-hardware runner download/launch/backend and recovery checks remain pending. The public archive’s publication history is recorded in RELEASE.md and is not replaced by this app merge.
