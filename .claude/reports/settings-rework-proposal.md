# Settings rework

Replace the legacy Setup window and Setup/Prefix menus with two destinations in Settings: Steam and Wine Prefixes. Use a sidebar Settings layout so the existing destinations remain readable as the list grows (native selection, grouped forms, restrained separators).

Steam owns the selected Steam location, integration status and existing install/update/repair actions, update blocking, Valve binaries and controller permission reset. Remove the required CrossOver.app status: runner management stays in Runners (currently Compatibility). Wine Prefixes embeds the existing prefix and backup views, preserving confirmations and tools, with visible selection actions rather than hidden menu-bar commands.

Show one integration issue banner in the library with a Settings action. Keep diagnostic refresh/log actions under Help > Troubleshooting. Remove number-key setup shortcuts entirely. Reuse the current SystemStatus/PrefixesModel operations; do not alter compatibility-tool registration. Localize changed UI in Italian and Simplified Chinese, update tests, run localization checks and app tests.
