# 0036 — Store installation and renderer engines

Status: Accepted for local 0.1.0 qualification.

Install opens a Cartouche review sheet for Steam, GOG, Epic and Amazon. The runner, graphics backend and destination are chosen before the download starts. Cancel leaves the saved setup unchanged. The game panel shows Setup only after installation.

GOG, Epic and Amazon keep their existing download clients and activity reporting. Steam keeps its authenticated background client as the download engine. Cartouche sends a bounded, expiring installation command through a private local file. Its Steam WebUI worker uses the authenticated transport to read that command and report its state. No Steam install URL is opened. Licenses require an explicit acceptance in Cartouche; the worker compares the exact license versions before accepting. Steam still has to be signed in.

Commands are limited to install, accept and cancel, include a request UUID and account ID, expire after five minutes and are checked against the current account. The worker checks ownership again. Status writes require the per-launch transport token. A handled command is not replayed after a WebUI restart. Native API calls have bounded waits.

Wine searches its installed builtins before WINEDLLPATH. Merely adding the toolkit directory therefore left CarX on wined3d/Vulkan. Each downloaded Wine now gets a renderer-specific engine under `runners/.graphics/<id>/<backend>`. Files are copied with APFS cloning where available; the selected backend replaces DLLs only in that engine. A receipt tracks the original engine and renderer file stamps. The original Wine remains available for other backends. CrossOver retains its own renderer selection.

The toolkit import includes its graphics DLLs as well as its Metal framework. D3DMetal unix aliases are created beside the renderer engine and point to the user's toolkit. Those Apple files are never added to the app bundle.

Qualification receipts are in the ignored `.scratch/qualification-0.1.0` directory. CarX reached its loading screen with Direct3D 11 / GPTK 4.0b3, and the user confirmed DualSense navigation in the menu. This does not establish compatibility for every game or backend.

Steam installation requests are transient: activity takes ownership as soon as the download or complete installation appears. They must be cleared so an uninstall does not revive a former queued request. Cartouche-initiated uninstall waits for Steam’s confirmation to remove the manifests, then deletes only the game’s dedicated compatdata prefix through PrefixTools. A missing library, cancelled uninstall, in-use prefix or redirected path must preserve data.
