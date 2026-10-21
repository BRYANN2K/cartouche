#!/usr/bin/env python3
"""make_world.py — build a fake macOS home folder for Cartouche QA.

    python3 qa/world/make_world.py <dir> [--profile beginner|medium|retro|senior|empty] [--force]

<dir> becomes a scratch HOME: launch the app with HOME=<dir> and every path the
app reads (~/Library/Application Support/Steam, ~/Games/ROMs, ~/Downloads,
~/Library/Caches/Cartouche, ~/Library/Preferences) resolves inside <dir>. The
user's real home is never touched.

Every file is deterministic: fixed bytes, fixed timestamps. Two runs produce
identical trees. Formats mirror the app's test fixtures (LibraryFixtures.swift,
ConsoleFixtures.swift, PortingToolkitTests.swift, AnalysisTests.swift and
SteamAppInfoTests.swift); the ROM bytes are identical to the ones the P13 tests
write, so their CRC32s match the recorded libretro rows, which the world also
installs as .rdb files.

All game files are synthetic homebrew made here; nothing is downloaded.
"""

import argparse
import datetime
import gzip
import hashlib
import json
import os
import plistlib
import shutil
import struct
import sys
import zlib
from pathlib import Path

# ---------------------------------------------------------------------------
# Shared constants — the SteamFixture account and app list, verbatim
# ---------------------------------------------------------------------------

STEAM_ID = "76561198000000042"
ACCOUNT_ID = "39734314"          # STEAM_ID - 76561197960265728
ACCOUNT = "player42"
PERSONA = "Player 42"
BUNDLE_ID = "dev.bryann2k.cartouche"

# One fixed clock for the whole world, so builds are byte-identical.
NOW = 1_792_000_000              # 2026-10-14T17:46:40Z
DAY = 86_400

# (appid, name, installed, days since last played or None, minutes played)
STEAM_APPS = [
    (1_245_620, "Elden Ring", True, 1, 954),
    (730, "Counter-Strike 2", True, 7, 420),
    (1_172_470, "Apex Legends", False, None, 0),
    (1_174_180, "Red Dead Redemption 2", True, 3, 450),
    (1_593_500, "God of War", False, None, 0),
    (1_091_500, "Cyberpunk 2077", True, None, 0),
    (1_086_940, "Baldur’s Gate 3", True, None, 0),
    (367_520, "Hollow Knight", True, None, 0),
]
# Steam's own runtime, listed but never a game (SteamLocalFiles.isTool).
STEAMWORKS = (228_980, "Steamworks Common Redistributables")

# oslist entries for appinfo.vdf, as SteamAppInfoTests writes them.
OSLIST = {
    1_245_620: "windows", 730: "windows", 1_172_470: "windows",
    1_174_180: "windows", 1_593_500: "windows",
    1_091_500: "macos,windows", 1_086_940: "windows,macos",
    367_520: "windows,macos,linux", 228_980: "windows",
}

# The recorded libretro rows our synthetic files answer to, verbatim from
# retroarch/Tests/RetroArchKitTests/Fixtures/database/rows.json (homebrew and
# fixture discs only; no published game's data is needed).
RDB_ROWS = {
    "Nintendo - Game Boy": [
        {"name": "Cartouche Quest (World)", "rom_name": "Cartouche Quest (World).gb",
         "size": 32768, "crc": "0e8b3192", "md5": "2117da792975fb39bc42f8903e54d7ef",
         "sha1": "4d4176a77c6c38a0487bbd9540a94f7dc30682f9"},
        {"name": "Cartouche Puzzle (World)", "rom_name": "Cartouche Puzzle (World).gb",
         "size": 32768, "crc": "0414d9d9", "md5": "aad00045f4a32d9719cc32e3f0dc5cb9",
         "sha1": "16bb3e1554b4074eb292b50ef6d17b3322d19b0c"},
        {"name": "Cartouche Race (World)", "rom_name": "Cartouche Race (World).gb",
         "size": 32768, "crc": "735c8190", "md5": "9249964dcdae2e2d76ff93dbac18f417",
         "sha1": "86418f9725ca2ca81e77312547898bb5644e5371"},
        {"name": "Cartouche Maze (World)", "rom_name": "Cartouche Maze (World).gb",
         "size": 32768, "crc": "80d95fd0", "md5": "2663344fb0e0084c31f6b8cbc509fe19",
         "sha1": "78e4837f395d818769d1d08e6f3c2e6a94d7c59d"},
    ],
    "Nintendo - Super Nintendo Entertainment System": [
        {"name": "Cartouche Homebrew (World)", "rom_name": "Cartouche Homebrew (World).sfc",
         "size": 32768, "crc": "3fa862e9", "md5": "17e68b69340359ef09c0789df4f4f963",
         "sha1": "d5786716c2de06b5fc688bbd02d9ef9b2d7cb556"},
    ],
    "Sony - PlayStation": [
        {"name": "Cartouche Test Disc (World)", "rom_name": "Cartouche Test Disc (World).bin",
         "serial": "SLUS-99901"},
        {"name": "Cartouche Test Saga (World) (Disc 1)",
         "rom_name": "Cartouche Test Saga (World) (Disc 1).bin", "serial": "SLUS-99902"},
        {"name": "Cartouche Test Saga (World) (Disc 2)",
         "rom_name": "Cartouche Test Saga (World) (Disc 2).bin", "serial": "SLUS-99903"},
    ],
}

# Console id -> libretro-database system name (ConsoleCatalog.system).
SYSTEMS = {"gb": "Nintendo - Game Boy", "snes": "Nintendo - Super Nintendo Entertainment System",
           "ps1": "Sony - PlayStation"}

PROFILES = ("empty", "beginner", "medium", "retro", "senior")


# ---------------------------------------------------------------------------
# Small deterministic file helpers
# ---------------------------------------------------------------------------

def _write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def _text(path: Path, text: str) -> None:
    _write(path, text.encode("utf-8"))


def _freeze(root: Path, stamp: int = NOW) -> None:
    """One mtime on every file, so two builds hash the same."""
    for dirpath, dirnames, filenames in os.walk(root):
        os.utime(dirpath, (stamp, stamp))
        for name in dirnames + filenames:
            os.utime(os.path.join(dirpath, name), (stamp, stamp), follow_symlinks=False)


def _png(width: int, height: int, rgb: tuple) -> bytes:
    """A solid-colour PNG, written with zlib only (CoverStore accepts PNG)."""
    row = b"\x00" + bytes(rgb) * width
    packed = zlib.compress(row * height)
    def chunk(tag: bytes, body: bytes) -> bytes:
        return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", zlib.crc32(tag + body))
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", packed) + chunk(b"IEND", b""))


def _plist(path: Path, obj) -> None:
    _write(path, plistlib.dumps(obj, fmt=plistlib.FMT_XML, sort_keys=True))


# ---------------------------------------------------------------------------
# Steam — mirrors SteamFixture (LibraryFixtures.swift) byte for byte
# ---------------------------------------------------------------------------

def _manifest(library: Path, appid: int, name: str, flags: int, last: int) -> None:
    _text(library / "steamapps" / f"appmanifest_{appid}.acf",
          '"AppState"\n{\n'
          f'\t"appid"\t\t"{appid}"\n'
          f'\t"name"\t\t"{name}"\n'
          f'\t"StateFlags"\t\t"{flags}"\n'
          f'\t"installdir"\t\t"{name}"\n'
          f'\t"LastPlayed"\t\t"{last}"\n'
          '}\n')
    (library / "steamapps" / "common" / name).mkdir(parents=True, exist_ok=True)


def build_appinfo() -> bytes:
    """The v29 appinfo.vdf cache, ported from SteamAppInfoTests.cache(.v29)."""
    table = ["appinfo", "common", "name", "oslist", "steam_release_date", "depots", "config"]

    def key(b: bytearray, name: str) -> None:
        b += struct.pack("<I", table.index(name))

    def entry(appid: int, oslist, common: bool = True) -> bytes:
        kv = bytearray()
        kv.append(0x00); key(kv, "appinfo")
        if common:
            kv.append(0x00); key(kv, "common")
            kv.append(0x01); key(kv, "name")
            kv += f"App {appid}".encode() + b"\x00"
            kv.append(0x02); key(kv, "steam_release_date"); kv += struct.pack("<I", 1_600_000_000)
            if oslist:
                kv.append(0x01); key(kv, "oslist"); kv += oslist.encode() + b"\x00"
            kv.append(0x08)
        kv.append(0x00); key(kv, "depots")
        kv.append(0x00); key(kv, "config")
        kv.append(0x01); key(kv, "oslist"); kv += b"linux\x00"
        kv += b"\x08\x08\x08\x08"
        return struct.pack("<II", appid, 60 + len(kv)) + bytes(60) + bytes(kv)

    entries = bytearray()
    for appid, _name, _inst, _p, _m in STEAM_APPS:
        entries += entry(appid, OSLIST[appid])
    entries += entry(STEAMWORKS[0], OSLIST[STEAMWORKS[0]])
    entries += entry(99, None, common=False)
    entries += struct.pack("<I", 0)

    out = bytearray(struct.pack("<IIQ", 0x07564429, 1, 16 + len(entries)))
    out += entries
    out += struct.pack("<I", len(table))
    for word in table:
        out += word.encode() + b"\x00"
    return bytes(out)


def write_steam(home: Path) -> Path:
    """~/Library/Application Support/Steam plus a second library on 'External'."""
    steam = home / "Library" / "Application Support" / "Steam"
    external = home / "External" / "SteamLibrary"
    (steam / "steamapps").mkdir(parents=True, exist_ok=True)
    (steam / "config").mkdir(parents=True, exist_ok=True)
    (steam / "userdata" / ACCOUNT_ID / "config" / "cloudstorage").mkdir(parents=True, exist_ok=True)
    (external / "steamapps").mkdir(parents=True, exist_ok=True)

    _text(steam / "config" / "loginusers.vdf", f'''"users"
{{
\t"76561197960265999"
\t{{
\t\t"AccountName"\t\t"someoneelse"
\t\t"PersonaName"\t\t"Other"
\t\t"MostRecent"\t\t"0"
\t\t"Timestamp"\t\t"1700000000"
\t}}
\t"{STEAM_ID}"
\t{{
\t\t"AccountName"\t\t"{ACCOUNT}"
\t\t"PersonaName"\t\t"{PERSONA}"
\t\t"MostRecent"\t\t"1"
\t\t"Timestamp"\t\t"1790000000"
\t}}
}}
''')

    _text(steam / "steamapps" / "libraryfolders.vdf", f'''"libraryfolders"
{{
\t"0"
\t{{
\t\t"path"\t\t"{steam}"
\t\t"apps" {{ "1245620" "1" }}
\t}}
\t"1"
\t{{
\t\t"path"\t\t"{external}"
\t}}
}}
''')

    # Installed games split between the two libraries exactly as the fixture:
    # even index in STEAM_APPS goes to the main library, odd to the external.
    for i, app in enumerate(STEAM_APPS):
        appid, name, installed, played, _minutes = app
        if not installed:
            continue
        library = steam if i % 2 == 0 else external
        _manifest(library, appid, name, 4, NOW - played * DAY if played else 0)
    # Downloading, not installed.
    _manifest(steam, 1_593_500, "God of War", 1026, 0)
    _manifest(steam, STEAMWORKS[0], STEAMWORKS[1], 4, 0)

    apps = "".join(
        f'"{appid}" {{ "LastPlayed" "{NOW - played * DAY if played else 0}" "Playtime" "{minutes}" }}\n'
        for appid, _n, _i, played, minutes in STEAM_APPS if minutes > 0)
    _text(steam / "userdata" / ACCOUNT_ID / "config" / "localconfig.vdf",
          '"UserLocalConfigStore"\n{\n'
          '\t"Software" { "Valve" { "Steam" { "Apps" {\n'
          f'{apps}'
          '\t} } } }\n'
          '}\n')

    rows = [
        ["user-collections.uc-souls",
         {"key": "user-collections.uc-souls", "timestamp": 1,
          "value": '{"id":"uc-souls","name":"Souls","added":[1245620,1174180,730],"removed":[730]}'}],
        ["user-collections.favorite",
         {"key": "user-collections.favorite", "timestamp": 1,
          "value": '{"id":"favorite","name":"","added":[730]}'}],
        ["user-collections.uc-old",
         {"key": "user-collections.uc-old", "timestamp": 1, "is_deleted": True,
          "value": '{"id":"uc-old","name":"Old","added":[367520]}'}],
    ]
    _write(steam / "userdata" / ACCOUNT_ID / "config" / "cloudstorage" / "cloud-storage-namespace-1.json",
           json.dumps(rows, separators=(",", ":")).encode())

    _write(steam / "appcache" / "appinfo.vdf", build_appinfo())

    # Steam's library art for every owned game (PNG bytes under .jpg names, as
    # the fixture does and CoverStore accepts).
    for i, (appid, name, *_rest) in enumerate(STEAM_APPS):
        hue = i / max(len(STEAM_APPS), 1)
        r = int(255 * (0.45 * (1 + 0.5 * hue)))
        folder = steam / "appcache" / "librarycache" / str(appid)
        _write(folder / "library_600x900.jpg", _png(300, 450, (r % 255, 90, 140)))
        _write(folder / "library_hero.jpg", _png(960, 310, (60, r % 255, 160)))
    return steam


def write_steam_app(home: Path) -> Path:
    """A Steam.app stand-in: the bundle path existing is what SteamBundle checks."""
    app = home / "Applications" / "Steam.app"
    _plist(app / "Contents" / "Info.plist", {
        "CFBundleIdentifier": "com.valvesoftware.steam",
        "CFBundleName": "Steam",
        "CFBundleExecutable": "steam_osx",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1.0",
        "CFBundlePackageType": "APPL",
    })
    exe = app / "Contents" / "MacOS" / "steam_osx"
    _write(exe, b"#!/bin/sh\n# Cartouche QA fixture: a stand-in for the Steam client.\nexit 0\n")
    exe.chmod(0o755)
    return app


def write_export(home: Path) -> Path:
    """What the running Steam client exports: every owned game."""
    export = {
        "version": 1, "generated": NOW, "steamid": STEAM_ID,
        "apps": [{"appid": appid, "name": name, "installed": installed,
                  "last_played": (NOW - played * DAY) if played else None,
                  "playtime": minutes, "hidden": False}
                 for appid, name, installed, played, minutes in STEAM_APPS],
        "collections": [{"id": "uc-souls", "name": "Souls", "apps": [1_245_620]}],
    }
    out = home / "Library" / "Application Support" / "Cartouche" / "steam-library.json"
    _write(out, json.dumps(export, separators=(",", ":")).encode())
    return out


# ---------------------------------------------------------------------------
# Runners — CrossOverSource and PortingToolkitSource fixtures
# ---------------------------------------------------------------------------

def write_crossover(home: Path) -> Path:
    """A CrossOver.app shaped like the real install. Detection works; the
    runner shows as an unsupported build because the pinned loader hashes in
    SupportedRunners cannot be forged by a fixture."""
    bundle = home / "Applications" / "CrossOver.app"
    _plist(bundle / "Contents" / "Info.plist", {
        "CFBundleIdentifier": "com.codeweavers.CrossOver",
        "CFBundleName": "CrossOver",
        "CFBundleExecutable": "CrossOver",
        "CFBundleShortVersionString": "26.3",
        "CFBundleVersion": "26.3.0.39832",
        "CFBundlePackageType": "APPL",
    })
    wine = bundle / "Contents" / "SharedSupport" / "CrossOver" / "lib" / "wine"
    for arch in ("x86_64-windows", "i386-windows", "aarch64-windows"):
        _write(wine / arch / "ntdll.dll", f"ntdll for {arch}".encode())
    loader = wine / "x86_64-unix" / "wine"
    _write(loader, b"wine loader")
    loader.chmod(0o755)
    _write(wine / "x86_64-unix" / "wineserver", b"wineserver")
    return bundle


def _gptk_lib(lib: Path, version: str) -> None:
    """The lib folder as PortingToolkitTests.toolkit() lays it out."""
    framework = lib / "external" / "D3DMetal.framework"
    _write(framework / "Versions" / "A" / "D3DMetal", f"fixture framework binary {version}".encode())
    _plist(framework / "Versions" / "A" / "Resources" / "Info.plist", {
        "CFBundleShortVersionString": version, "CFBundleIdentifier": "com.apple.D3DMetal"})
    (framework / "Versions" / "Current").symlink_to("A")
    (framework / "D3DMetal").symlink_to("Versions/Current/D3DMetal")
    _write(lib / "external" / "libd3dshared.dylib", b"fixture shared")
    _write(lib / "wine" / "x86_64-windows" / "d3d12.dll", b"MZ fixture")


def write_gptk(home: Path, support: Path, version: str = "3.0") -> Path:
    """Game Porting Toolkit.app the detector accepts (Contents/Resources/wine/lib),
    plus the copy into Cartouche's runners folder a finished setup leaves."""
    app = home / "Applications" / "Game Porting Toolkit.app"
    _plist(app / "Contents" / "Info.plist", {
        "CFBundleIdentifier": "com.cartouche.fixture.gptk",
        "CFBundleName": "Game Porting Toolkit",
        "CFBundleShortVersionString": version,
        "CFBundlePackageType": "APPL",
    })
    _gptk_lib(app / "Contents" / "Resources" / "wine" / "lib", version)

    # The copied runner: runners/gptk-<version>/lib plus the receipt.
    copied = support / "runners" / f"gptk-{version}"
    _gptk_lib(copied / "lib", version)
    files = {}
    for path in sorted((copied / "lib").rglob("*")):
        if path.is_file() and not path.is_symlink():
            files["lib/" + str(path.relative_to(copied / "lib"))] = hashlib.sha256(path.read_bytes()).hexdigest()
    receipt = {"version": version, "origin": str(app), "files": files}
    _write(copied / ".cartouche-runner.json", json.dumps(receipt, sort_keys=True).encode())
    return app


def write_broken_runner(support: Path) -> Path:
    """A clone of a pinned CrossOver build that lost its payload: lib/wine is
    there, the loader and ntdll are gone, so it reports damaged."""
    root = support / "runners" / "crossover-26.3.0.39832" / "CrossOver"
    _write(root / "lib" / "wine" / "README.txt", b"This clone is missing its loader and ntdll.\n")
    return root


def write_free_runner(support: Path) -> Path:
    """The manifest-pinned Wine build installed and intact: runners/wine-<id>
    with the watched files and the receipt WineRunnerInstaller.verify reads.
    Reported .ready — the 'one free runner' of the steam profile."""
    build_id = "wine-stable-11.0_1"          # runners.json, first pinned build
    archive_sha = "b50dc50ec7f41d58b115a6b685d4d1315ba3c797bd3aa0f49213f2703cb82388"
    root = support / "runners" / f"wine-{build_id}"
    watched = {}
    for rel in ["bin/wine", "bin/wineserver",
                "lib/wine/x86_64-windows/ntdll.dll",
                "lib/wine/i386-windows/ntdll.dll",
                "lib/wine/aarch64-windows/ntdll.dll"]:
        body = f"cartouche fixture {rel}\n".encode()
        _write(root / rel, body)
        watched[rel] = hashlib.sha256(body).hexdigest()
    (root / "bin" / "wine").chmod(0o755)
    receipt = {"id": build_id, "archiveSHA256": archive_sha, "files": watched}
    _write(root / ".cartouche-runner.json", json.dumps(receipt, sort_keys=True).encode())
    return root


def write_dolphin(home: Path) -> Path:
    """A fake Dolphin.app under the QA ~/Applications: Info.plist + an
    executable Contents/MacOS/Dolphin is all EmulatorDetector reads."""
    app = home / "Applications" / "Dolphin.app"
    _plist(app / "Contents" / "Info.plist", {
        "CFBundleIdentifier": "org.dolphin-emu.dolphin",
        "CFBundleName": "Dolphin",
        "CFBundleExecutable": "Dolphin",
        "CFBundleShortVersionString": "2509",
        "CFBundleVersion": "2509",
        "CFBundlePackageType": "APPL",
    })
    exe = app / "Contents" / "MacOS" / "Dolphin"
    _write(exe, b"#!/bin/sh\n# Cartouche QA fixture: a stand-in for Dolphin.\nexit 0\n")
    exe.chmod(0o755)
    return app


# ---------------------------------------------------------------------------
# Console games — the P13 fixtures byte for byte
# ---------------------------------------------------------------------------

# The 48-byte logo every Game Boy cart carries at 0x104.
GB_LOGO = bytes([
    0xCE, 0xED, 0x66, 0x66, 0xCC, 0x0D, 0x00, 0x0B, 0x03, 0x73, 0x00, 0x83,
    0x00, 0x0C, 0x00, 0x0D, 0x00, 0x08, 0x11, 0x1F, 0x88, 0x89, 0x00, 0x0E,
    0xDC, 0xCC, 0x6E, 0xE6, 0xDD, 0xDD, 0xD9, 0x99, 0xBB, 0xBB, 0x67, 0x63,
    0x6E, 0x0E, 0xEC, 0xCC, 0xDD, 0xDC, 0x99, 0x9F, 0xBB, 0xB9, 0x33, 0x3E])

# The 156-byte logo every GBA cart carries at 0x04.
GBA_LOGO = bytes([
    0x24, 0xFF, 0xAE, 0x51, 0x69, 0x9A, 0xA2, 0x21, 0x3D, 0x84, 0x82, 0x0A,
    0x84, 0xE4, 0x09, 0xAD, 0x11, 0x24, 0x8B, 0x98, 0xC0, 0x81, 0x7F, 0x21,
    0xA3, 0x52, 0xBE, 0x19, 0x93, 0x09, 0xCE, 0x20, 0x10, 0x46, 0x4A, 0x4A,
    0xF8, 0x27, 0x31, 0xEC, 0x58, 0xC7, 0xE8, 0x33, 0x82, 0xE3, 0xCE, 0xBF,
    0x85, 0xF4, 0xDF, 0x94, 0xCE, 0x4B, 0x09, 0xC1, 0x94, 0x56, 0x8A, 0xC0,
    0x13, 0x72, 0xA7, 0xFC, 0x9F, 0x84, 0x4D, 0x73, 0xA3, 0xCA, 0x9A, 0x61,
    0x58, 0x97, 0xA3, 0x27, 0xFC, 0x03, 0x98, 0x76, 0x23, 0x1D, 0xC7, 0x61,
    0x03, 0x04, 0xAE, 0x56, 0xBF, 0x38, 0x84, 0x00, 0x40, 0xA7, 0x0E, 0xFD,
    0xFF, 0x52, 0xFE, 0x03, 0x6F, 0x95, 0x30, 0xF1, 0x97, 0xFB, 0xC0, 0x85,
    0x60, 0xD6, 0x80, 0x25, 0xA9, 0x63, 0xBE, 0x03, 0x01, 0x4E, 0x38, 0xE2,
    0xF9, 0xA2, 0x34, 0xFF, 0xBB, 0x3E, 0x03, 0x44, 0x78, 0x00, 0x90, 0xCB,
    0x88, 0x11, 0x3A, 0x94, 0x65, 0xC0, 0x7C, 0x63, 0x87, 0xF0, 0x3C, 0xAF,
    0xD6, 0x25, 0xE4, 0x8B, 0x38, 0x0A, 0xAC, 0x72, 0x21, 0xD4, 0xF8, 0x07])


def homebrew_gb(title: str, fill: int = 0x00) -> bytes:
    """ConsoleFixtures.homebrewGB: 32 KiB, logo at 0x104, title at 0x134."""
    rom = bytearray([fill] * (32 * 1024))
    rom[0x104:0x134] = GB_LOGO
    name = title.encode()[:15]
    rom[0x134:0x134 + len(name)] = name
    return bytes(rom)


def homebrew_gba(title: str, code: str, fill: int = 0x00) -> bytes:
    """A 32 KiB homebrew GBA cartridge: entry branch, the Nintendo logo at
    0x04, title/game code/maker at 0xA0-0xB1, the fixed 0x96 byte and a
    correct header checksum."""
    rom = bytearray([fill] * (32 * 1024))
    rom[0x00:0x04] = b"\x2e\x00\x00\xea"          # b 0xc0
    rom[0x04:0xA0] = GBA_LOGO
    rom[0xA0:0xA0 + 12] = title.encode()[:12].ljust(12, b"\x00")
    rom[0xAC:0xB0] = code.encode()[:4].ljust(4, b" ")
    rom[0xB0:0xB2] = b"42"
    rom[0xB2] = 0x96
    rom[0xBD] = (-(0x19 + sum(rom[0xA0:0xBD]))) & 0xFF
    return bytes(rom)


def homebrew_snes(title: str = "CARTOUCHE HOMEBREW", fill: int = 0x42) -> bytes:
    """ConsoleFixtures.homebrewSNES: 32 KiB of LoROM, 21-byte title at 0x7FC0."""
    rom = bytearray([fill] * (32 * 1024))
    name = title.encode()[:21].ljust(21, b"\x20")
    rom[0x7FC0:0x7FD5] = name
    rom[0x7FD5] = 0x20
    return bytes(rom)


def ps1_disc(folder: Path, name: str, serial: str) -> Path:
    """ConsoleFixtures.disc: a 26-sector track carrying the boot serial."""
    track = bytearray(2352 * 26)
    boot = f"BOOT = cdrom:\\{serial};1\r\nTCB = 4\r\n".encode()
    at = 2352 * 24 + 24
    track[at:at + len(boot)] = boot
    _write(folder / f"{name}.bin", bytes(track))
    cue = folder / f"{name}.cue"
    _text(cue, f'FILE "{name}.bin" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n')
    return cue


def write_roms(home: Path) -> Path:
    roms = home / "Games" / "ROMs"
    gb = roms / "Game Boy"
    for file, title, fill in [
            ("Cartouche Quest (World).gb", "CARTOUCHE QUEST", 0),
            ("Cartouche Puzzle (World).gb", "CARTOUCHE PUZZL", 1),
            ("Cartouche Race (World).gb", "CARTOUCHE RACE", 2),
            ("Cartouche Maze (World).gb", "CARTOUCHE MAZE", 3)]:
        _write(gb / file, homebrew_gb(title, fill))

    gba = roms / "Game Boy Advance"
    _write(gba / "Cart Demo (World).gba", homebrew_gba("CART DEMO", "CT01", fill=0x11))
    _write(gba / "Tiny Demo (World).gba", homebrew_gba("TINY DEMO", "CT02", fill=0x22))

    snes = roms / "Super Nintendo"
    # Identical to ConsoleFixtures.homebrewSNES() -> matches the .rdb row.
    _write(snes / "Cartouche Homebrew (World).sfc", homebrew_snes())
    # A second homebrew the database does not know: the import sheet shows it
    # as "Not recognized" with the console picker.
    _write(snes / "cartouche_extra.sfc", homebrew_snes("CARTOUCHE EXTRA", fill=0x24))

    saga = roms / "PlayStation" / "Saga"
    ps1_disc(saga, "Saga (Disc 1)", "SLUS_999.02")
    ps1_disc(saga, "Saga (Disc 2)", "SLUS_999.03")
    _text(saga / "Saga.m3u", "Saga (Disc 1).cue\nSaga (Disc 2).cue\n")

    # One file nothing recognizes: an extension no console claims.
    _write(roms / "mystery.iso", bytes([0xC0 + i % 64 for i in range(4096)]))
    return roms


# ---------------------------------------------------------------------------
# The libretro database files the identifier reads, in the app's RetroArch
# folder, written as RDB.write writes them (libretro-db MessagePack).
# ---------------------------------------------------------------------------

def rdb_write(entries: list) -> bytes:
    out = bytearray(b"RARCHDB\x00" + bytes(8))

    def string(s: str) -> None:
        b = s.encode()
        if len(b) < 32:
            out.append(0xA0 | len(b))
        else:
            out.extend(b"\xd9" + bytes([len(b)]))
        out.extend(b)

    def raw(b: bytes) -> None:
        out.extend(b"\xc4" + bytes([len(b)]) + b)

    for e in entries:
        fields = [("name", lambda: string(e["name"]))]
        if e.get("rom_name"):
            fields.append(("rom_name", lambda e=e: string(e["rom_name"])))
        if e.get("size") is not None:
            fields.append(("size", lambda e=e: out.extend(b"\xcf" + struct.pack(">Q", e["size"]))))
        if e.get("crc"):
            fields.append(("crc", lambda e=e: raw(struct.pack(">I", int(e["crc"], 16)))))
        if e.get("md5"):
            fields.append(("md5", lambda e=e: raw(bytes.fromhex(e["md5"]))))
        if e.get("sha1"):
            fields.append(("sha1", lambda e=e: raw(bytes.fromhex(e["sha1"]))))
        if e.get("serial"):
            fields.append(("serial", lambda e=e: raw(e["serial"].encode())))
        out.append(0x80 | len(fields))
        for name, emit in fields:
            string(name)
            emit()
    out.append(0xC0)
    offset = len(out)
    out[8:16] = struct.pack(">Q", offset)
    out.append(0x81)
    string("count")
    out += b"\xcf" + struct.pack(">Q", len(entries))
    return bytes(out)


def write_database(support: Path) -> Path:
    folder = support / "retroarch" / "database"
    for console, system in SYSTEMS.items():
        _write(folder / f"{system}.rdb", rdb_write(RDB_ROWS[system]))
    return folder


# ---------------------------------------------------------------------------
# The Cartouche support folder
# ---------------------------------------------------------------------------

def write_compat_cache(support: Path, corrupt: bool, stale: bool = False) -> Path:
    """The compatibility cache. 'corrupt' writes the damaged copy the client
    ignores (CompatibilityClientTests.damagedCache / corruptDownload); 'stale'
    keeps it valid but rewinds 'generated' four days, so the offline banner
    reads 'Compatibility data from N days ago' with N > 3."""
    valid = _compat_gz()
    data = valid
    if stale:
        doc = json.loads(gzip.decompress(valid))
        old = datetime.datetime.fromtimestamp(NOW - 4 * DAY, datetime.timezone.utc)
        doc["generated"] = old.isoformat().replace("+00:00", "Z")
        data = gzip.compress(json.dumps(doc, separators=(",", ":")).encode(), mtime=0)
    if corrupt:
        data = bytearray(data)
        data[len(data) // 2] ^= 0xFF
        data = bytes(data)
    out = support / "compatibility" / "compat.json.gz"
    _write(out, data)
    return out


def _compat_gz() -> bytes:
    repo = Path(__file__).resolve().parents[2]
    fixture = repo / "tools" / "compat" / "fixtures" / "compat-2026-10-19.json.gz"
    if fixture.is_file():
        return fixture.read_bytes()
    # Fallback: a minimal schema-valid file, gzip with mtime 0 to stay fixed.
    doc = {
        "schema_version": 1, "generated": "2026-10-19T03:17:00Z",
        "sources": {k: {"name": k, "credit": k, "url": "https://example.org",
                        "license": "ODbL", "license_url": "https://example.org/l",
                        "attribution": k, "fetched": "2026-10-19", "status": "fresh"}
                    for k in ("applegamingwiki", "protondb", "areweanticheatyet")},
        "gpu_strength": {"M4": 1.0},
        "records": {"632470": {"name": "Disco Elysium"}},
    }
    return gzip.compress(json.dumps(doc, separators=(",", ":")).encode(), mtime=0)


def write_console_state(support: Path, home: Path) -> None:
    """A console library the app shows at once: four consoles added with their
    fake cores, the fixture games in library.json, the ROM folder watched."""
    root = support / "retroarch"
    _write(root / "consoles.json", json.dumps(["gb", "gba", "ps1", "snes"]).encode())
    _write(root / "folders.json", b'{\n  "addAutomatically" : true\n}')

    cores = {"gb": "sameboy", "gba": "mgba", "ps1": "swanstation", "snes": "snes9x"}
    records = []
    for core in sorted(set(cores.values())):
        body = b"\xcf\xfa\xed\xfe" + f"cartouche test core 1 {core}".encode()
        dylib = f"{core}_libretro.dylib"
        _write(root / "cores" / dylib, body)
        records.append({
            "core": core, "file": dylib, "size": len(body),
            "sha256": hashlib.sha256(body).hexdigest(),
            "source": f"https://buildbot.libretro.com/nightly/apple/osx/arm64/latest/{dylib}.zip",
            "recorded": "2026-10-18T10:00:00Z",
        })
        info = f'display_name = "{core}"\n'
        if core == "swanstation":
            info += ('firmware_count = 1\nfirmware0_desc = "scph5501.bin"\n'
                     'firmware0_path = "scph5501.bin"\nfirmware0_opt = "true"\n'
                     'notes = "(!) scph5501.bin (md5): 490f666e1afb15b7362b406ed1cea246"\n')
        _text(root / "info" / f"{core}_libretro.info", info)
    _write(root / "cores.json", json.dumps(records, sort_keys=True).encode())

    roms = home / "Games" / "ROMs"
    added = "2026-10-18T10:00:00Z"
    games = []
    for row in RDB_ROWS["Nintendo - Game Boy"]:
        title = row["name"].replace(" (World)", "")
        games.append({
            "id": f"console:gb:{row['name']}", "console": "gb", "name": title,
            "databaseName": row["name"],
            "file": str(roms / "Game Boy" / row["rom_name"]), "discs": [],
            "identifiedBy": "checksum", "added": added, "lastPlayed": None,
            "playSeconds": 0,
            "setup": {"core": None, "look": "original", "lowerInputLag": True,
                      "hardcore": False, "disc": 0},
        })
    saga = roms / "PlayStation" / "Saga"
    games.append({
        "id": "console:ps1:Cartouche Test Saga (World) (Disc 1)", "console": "ps1",
        "name": "Cartouche Test Saga", "databaseName": "Cartouche Test Saga (World) (Disc 1)",
        "file": str(saga / "Saga.m3u"),
        "discs": [str(saga / "Saga (Disc 1).cue"), str(saga / "Saga (Disc 2).cue")],
        "identifiedBy": "discID", "added": added, "lastPlayed": None, "playSeconds": 0,
        "setup": {"core": None, "look": "original", "lowerInputLag": True,
                  "hardcore": False, "disc": 0},
    })
    row = RDB_ROWS["Nintendo - Super Nintendo Entertainment System"][0]
    games.append({
        "id": "console:snes:Cartouche Homebrew (World)", "console": "snes",
        "name": "Cartouche Homebrew", "databaseName": row["name"],
        "file": str(roms / "Super Nintendo" / row["rom_name"]), "discs": [],
        "identifiedBy": "checksum", "added": added, "lastPlayed": None, "playSeconds": 0,
        "setup": {"core": None, "look": "original", "lowerInputLag": True,
                  "hardcore": False, "disc": 0},
    })
    _write(root / "library.json", json.dumps(games, indent=1, sort_keys=True).encode())


def write_save_states(support: Path) -> Path:
    """The 'save states with pictures' of the retro profile: an auto state and
    slot 1 (with its .png) for the SNES game, named as SaveStates.list expects
    (<contentName>.state[.auto|.N][.png]), one folder per core."""
    states = support / "retroarch" / "states" / "snes9x"
    for suffix, body in [(".state.auto", b"auto state bytes\n"),
                         (".state1", b"slot 1 state bytes\n")]:
        _write(states / f"Cartouche Homebrew (World){suffix}", body)
    _write(states / "Cartouche Homebrew (World).state1.png", _png(320, 240, (40, 120, 200)))
    return states


# ---------------------------------------------------------------------------
# Downloads — the P6 synthetic multi-part installer set
# ---------------------------------------------------------------------------

def write_installer(home: Path) -> Path:
    """AnalysisTests' shape: setup.exe stand-in, data-01/02.bin, and
    MD5/checksums.md5 listing a data-03.bin that is missing and may be
    optional, so the sheet shows it orange and keeps Install enabled."""
    folder = home / "Downloads" / "Disco Elysium (Offline Installer) v1.0.4"
    parts = {
        "data-01.bin": bytes((i * 7 + 1) % 256 for i in range(256 * 1024)),
        "data-02.bin": bytes((i * 5 + 3) % 256 for i in range(128 * 1024)),
    }
    _write(folder / "setup.exe", b"MZ" + b"cartouche fixture setup\x00" * 64)
    _write(folder / "unarc.dll", b"MZ unarc fixture")
    for name, body in parts.items():
        _write(folder / name, body)
    lines = "".join(
        f"{hashlib.md5(body).hexdigest()} *..\\{name}\r\n" for name, body in sorted(parts.items()))
    lines += f"{'0' * 32} *..\\data-03.bin\r\n"
    _text(folder / "MD5" / "checksums.md5",
          "; some parts are optional downloads\r\n" + lines)
    return folder


# ---------------------------------------------------------------------------
# Assembly
# ---------------------------------------------------------------------------

def write_preferences(home: Path, prefs: dict) -> None:
    _plist(home / "Library" / "Preferences" / f"{BUNDLE_ID}.plist", prefs)


def build(directory: Path, profile: str, damage: bool = False, stale: bool = False) -> dict:
    """Build <dir> as a scratch HOME for the profile; returns the summary.
    damage plants the broken-machine extras on top: a runner clone with its
    payload missing and a corrupt compatibility cache. stale ages the
    compatibility cache past the fresh window (the offline profile)."""
    if profile not in PROFILES:
        raise ValueError(f"unknown profile {profile!r} (one of {', '.join(PROFILES)})")
    if damage and profile not in ("medium", "retro", "senior"):
        raise ValueError("--damage needs a profile with a world (medium, retro, senior)")
    if stale and profile not in ("medium", "retro", "senior"):
        raise ValueError("--stale needs a profile with a world (medium, retro, senior)")
    home = directory.resolve()
    if home in (Path("/"), Path.home().resolve()):
        raise ValueError(f"a scratch world is never built over {home}")
    home.mkdir(parents=True, exist_ok=True)
    if any(home.iterdir()):
        raise FileExistsError(f"{home} is not empty; pass --force to rebuild it")

    made = {"profile": profile, "home": str(home), "wrote": []}
    note = made["wrote"].append

    if profile != "empty":
        # A home that looks lived in, whatever the profile adds on top.
        for folder in ("Desktop", "Documents", "Downloads", "Library"):
            (home / folder).mkdir(parents=True, exist_ok=True)

    support = home / "Library" / "Application Support" / "Cartouche"
    prefs = {}

    if profile == "beginner":
        # Nothing to find: no Steam, no runners, no game folders.
        _text(home / "Documents" / "notes.txt", "Nothing for Cartouche here.\n")
        note("empty-ish home")
    elif profile in ("medium", "retro", "senior"):
        steam = write_steam(home)
        app = write_steam_app(home)
        write_export(home)
        write_roms(home)
        write_database(support)
        write_installer(home)
        write_compat_cache(support, corrupt=damage, stale=stale)
        write_free_runner(support)
        note(f"{steam} and {app}")

        prefs["steamAppPath"] = str(app)
        if profile in ("retro", "senior"):
            prefs["library.gameFolders"] = [str(home / "Games" / "ROMs")]
            write_console_state(support, home)
            write_save_states(support)
            note("console library: gb, gba, ps1 and snes added, save states")
        if profile == "senior":
            write_crossover(home)
            write_gptk(home, support)
            write_dolphin(home)
            note("CrossOver.app (unsupported build), Game Porting Toolkit.app, "
                 "copied gptk-3.0 runner, wine-stable-11.0_1, Dolphin.app")
        if damage:
            write_broken_runner(support)
            note("damaged crossover-26.3.0.39832 clone, corrupt compat.json.gz")

    # Every profile pins steamAppPath inside the scratch home; a profile with
    # no Steam.app points at the missing fixture, never the real /Applications.
    prefs.setdefault("steamAppPath", str(home / "Applications" / "Steam.app"))
    write_preferences(home, prefs)
    note(f"{BUNDLE_ID}.plist: {sorted(prefs)}")

    manifest = home / "cartouche-world.json"
    _write(manifest, json.dumps(made, indent=1, sort_keys=True).encode() + b"\n")
    _freeze(home)
    return made


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0],
                                     epilog="\n".join(__doc__.splitlines()[1:11]),
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("dir", type=Path, help="the scratch HOME to build")
    parser.add_argument("--profile", choices=PROFILES, default="medium")
    parser.add_argument("--force", action="store_true", help="replace a non-empty dir")
    parser.add_argument("--damage", action="store_true",
                        help="plant the broken-machine extras (damaged runner, corrupt cache)")
    parser.add_argument("--stale", action="store_true",
                        help="age the compatibility cache past the fresh window")
    args = parser.parse_args(argv)

    if args.force and args.dir.exists() and args.dir.is_dir() and any(args.dir.iterdir()):
        if not (args.dir / "cartouche-world.json").is_file():
            print(f"make_world: --force only replaces a folder a world was built in; "
                  f"{args.dir} holds something else", file=sys.stderr)
            return 2
        shutil.rmtree(args.dir)
    try:
        made = build(args.dir, args.profile, damage=args.damage, stale=args.stale)
    except (FileExistsError, ValueError) as error:
        print(f"make_world: {error}", file=sys.stderr)
        return 2
    print(f"built {made['profile']} world at {made['home']}")
    for line in made["wrote"]:
        print(f"  {line}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
