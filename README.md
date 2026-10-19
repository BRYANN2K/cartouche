# Cartouche

Cartouche is a free macOS game launcher for Apple silicon Macs. It runs Windows games through Steam Play inside the Mac Steam client, using CrossOver as the runner.

Cartouche is a fork of [NotProton](https://github.com/NotProtonNot/NotProton) and is built on its code. Store clients, other runners and a new launcher interface are planned.

**Status: early development.** There is no release yet. Expect missing features and breaking changes.

## What it does today

Cartouche forcibly enables the Steam Play functionality in macOS Steam (which is present and inert) and ports some components of Valve's Proton to macOS. This is NotProton's design, unchanged so far.

It is intended to be used with the stable Steam Client (version 1791918634) as well as the beta Steam Client (version 1792192922) paired with **CrossOver 26.3 or CrossOver [Preview](https://www.codeweavers.com/preview) 20261006 / 20260821 / 20261015**.

**NTFS file systems/drivers are not currently supported.**

Both the FEX and the Rosetta versions of CrossOver are supported. The FEX version of Preview 20261006 includes both the FEX and the Rosetta versions.

A good default is to go into Steam Settings - Compatibility and select the Rosetta version as your default compatibility tool. You can select FEX on a per game basis by right clicking a game in Steam, going into Properties - Compatibility and selecting FEX there.

If a game has a native macOS version as well as a Windows one, Steam will download the macOS version. To override this behavior, right click on the game, select Properties, select Compatibility. Enable 'Force the use of a specific Steam Play compatibility tool'. Select whichever version of CrossOver you want to use. That will make Steam download the Windows version. Unchecking the 'Force the use...' box or selecting 'No Compatibility Tool' in the drop down list will revert to the macOS version of the game, with the specifics there varying based on your Steam version.

**Valve Anti-Cheat is not supported.** Proton itself does not support VAC in Valve titles; Valve ships native Linux ports instead. VAC titles will launch in Insecure Mode and will not allow matchmaking.

Cartouche keeps its files in `~/Library/Application Support/Cartouche` and its logs in `~/Library/Logs/Cartouche`, so it does not share them with a NotProton install on the same Mac.

## Developer notes

The macOS app is located in the `app` folder. The core logic is in `dylib`.
`lsteamclient` is a macOS port of Valve's lsteamclient. `steam-shim` is a port of Valve's
steam-helper from Proton 9.0. `ntdll-patch` patches the copy of CrossOver that the app
makes/places in the `~/Library/Application Support/Cartouche/runners/` folder so that
lsteamclient is loaded. `tools/make-icon.swift` builds the app icon from `mockup/brand`.

## Credits

Cartouche is built on [NotProton](https://github.com/NotProtonNot/NotProton), created by NotProtonNot with the NotProton contributors. Most of the code in this repository is theirs.

The NotProton author also thanks the people who worked on similar ideas before it:

- [Nat Brown](https://github.com/natbro) made [Kaon](https://github.com/natbro/kaon), which is similar in goals to NotProton.
- mont127's [Neutron](https://github.com/mont127/Neutron) is also a similar idea, but implemented differently.
- [Gio](https://github.com/giodotblue) was working on enabling Steam Play inside of Steam on macOS prior to the release of NotProton itself.

And everyone who has positively contributed to macOS gaming.

## License

Cartouche is free software, licensed under the GNU General Public License version 3 (GPL-3.0), like NotProton. See LICENSE. Some parts carry the licenses of their original authors (Valve, the Steamworks SDK, Sparkle, fonts and others); NOTICE and THIRD-PARTY-LICENSES list them. What Cartouche asks macOS for and what it sends over the network is in docs/PRIVACY.md.

Cartouche is an independent project. It is not affiliated with NotProton, Valve, Apple or CodeWeavers.
