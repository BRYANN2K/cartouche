#!/usr/bin/env python3
"""Tests for make_world.py: each profile builds in a temp dir, and the files
the app's readers look for are there and well formed.

    python3 qa/world/test_make_world.py    (or: python3 -m unittest)
"""

import datetime
import gzip
import hashlib
import json
import os
import plistlib
import struct
import sys
import tempfile
import unittest
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_world


def tree_hash(root: Path) -> str:
    """Every file's relative path, size and sha256, and every symlink target."""
    out = hashlib.sha256()
    for path in sorted(root.rglob("*"), key=lambda p: str(p)):
        rel = str(path.relative_to(root))
        if path.is_symlink():
            out.update(f"L {rel} -> {path.readlink()}\n".encode())
        elif path.is_file():
            out.update(f"F {rel} {path.stat().st_size} ".encode())
            out.update(path.read_bytes())
            out.update(b"\n")
        else:
            out.update(f"D {rel}\n".encode())
    return out.hexdigest()


class MakeWorldTests(unittest.TestCase):
    def build(self, profile, damage=False, stale=False):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        home = (Path(tmp.name) / "home").resolve()
        made = make_world.build(home, profile, damage=damage, stale=stale)
        return home, made

    # -- profiles ----------------------------------------------------------

    def test_empty(self):
        home, made = self.build("empty")
        self.assertEqual(made["profile"], "empty")
        # Only the manifest and the preferences pinning steamAppPath inside
        # the scratch home — nothing the app scans exists.
        rest = [p for p in home.rglob("*")
                if p.name not in ("cartouche-world.json", f"{make_world.BUNDLE_ID}.plist",
                                  "Library", "Preferences")]
        self.assertEqual(rest, [])

    def test_every_profile_pins_steam_path_inside_the_home(self):
        # Without the pin the app falls back to a default; in QA that default is
        # under the scratch home, but the pin keeps it there even if QA mode is
        # off — the real /Applications/Steam.app is never the answer.
        for profile in make_world.PROFILES:
            with self.subTest(profile=profile):
                home, _ = self.build(profile)
                prefs = plistlib.loads(
                    (home / "Library" / "Preferences"
                     / f"{make_world.BUNDLE_ID}.plist").read_bytes())
                pinned = Path(prefs["steamAppPath"])
                self.assertEqual(pinned, home / "Applications" / "Steam.app")
                if profile in ("empty", "beginner"):
                    # No Steam.app fixture exists: the pin points at a missing
                    # path, so nothing ever lands in the real Steam.
                    self.assertFalse(pinned.exists())
                    self.assertFalse((home / "Applications").exists())
                else:
                    self.assertTrue((pinned / "Contents/Info.plist").is_file())

    def test_beginner_has_nothing_to_find(self):
        home, _ = self.build("beginner")
        self.assertFalse((home / "Library/Application Support/Steam").exists())
        self.assertFalse((home / "Applications").exists())
        self.assertFalse((home / "Games").exists())
        # The folder scan's protected and candidate folders hold no games.
        self.assertTrue((home / "Documents").is_dir())
        self.assertTrue((home / "Downloads").is_dir())

    def test_refuses_non_empty_dir(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp) / "home"
            make_world.build(home, "empty")
            with self.assertRaises(FileExistsError):
                make_world.build(home, "empty")

    def test_refuses_a_real_home(self):
        # A world builds only into a scratch dir, never over the real ~ or /
        for real in (Path.home(), Path("/")):
            with self.assertRaises(ValueError, msg=str(real)):
                make_world.build(real, "empty")

    def test_force_needs_a_built_world(self):
        # --force removes the target: it must never be pointed at a folder
        # that is not a world this tool built
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "something").write_text("x")
            self.assertEqual(make_world.main([tmp, "--force"]), 2)
            self.assertTrue(Path(tmp, "something").exists())
            Path(tmp, "cartouche-world.json").write_text("{}")
            self.assertEqual(make_world.main([tmp, "--force", "--profile", "empty"]), 0)
            self.assertTrue((Path(tmp) / "cartouche-world.json").is_file())

    # -- the Steam fixture -------------------------------------------------

    def test_medium_steam(self):
        home, _ = self.build("medium")
        steam = home / "Library" / "Application Support" / "Steam"

        loginusers = (steam / "config" / "loginusers.vdf").read_text()
        self.assertIn('"player42"', loginusers)
        self.assertIn(f'"{make_world.STEAM_ID}"', loginusers)
        self.assertIn('"MostRecent"\t\t"1"', loginusers)

        folders = (steam / "steamapps" / "libraryfolders.vdf").read_text()
        self.assertIn(str(steam), folders)
        self.assertIn(str(home / "External" / "SteamLibrary"), folders)

        # 6 installed across the two libraries, 1 downloading, 1 tool.
        main = list((steam / "steamapps").glob("appmanifest_*.acf"))
        ext = list((home / "External/SteamLibrary/steamapps").glob("appmanifest_*.acf"))
        self.assertEqual(len(main) + len(ext), 8)
        downloading = (steam / "steamapps" / "appmanifest_1593500.acf").read_text()
        self.assertIn('"StateFlags"\t\t"1026"', downloading)
        for appid, _n, installed, _p, _m in make_world.STEAM_APPS:
            if installed:
                self.assertTrue(any(f"appmanifest_{appid}.acf" == p.name for p in main + ext))

        localconfig = (steam / "userdata" / make_world.ACCOUNT_ID
                       / "config" / "localconfig.vdf").read_text()
        self.assertIn('"1245620" { "LastPlayed"', localconfig)
        self.assertIn('"Playtime" "954"', localconfig)

        cloud = json.loads((steam / "userdata" / make_world.ACCOUNT_ID / "config"
                            / "cloudstorage" / "cloud-storage-namespace-1.json").read_bytes())
        self.assertEqual(cloud[0][0], "user-collections.uc-souls")
        self.assertTrue(cloud[2][1]["is_deleted"])

        appinfo = (steam / "appcache" / "appinfo.vdf").read_bytes()
        self.assertEqual(struct.unpack("<I", appinfo[:4])[0], 0x07564429)
        offset = struct.unpack("<Q", appinfo[8:16])[0]
        table_count = struct.unpack("<I", appinfo[offset:offset + 4])[0]
        self.assertEqual(table_count, 7)

        cover = steam / "appcache" / "librarycache" / "1245620" / "library_600x900.jpg"
        self.assertEqual(cover.read_bytes()[:8], b"\x89PNG\r\n\x1a\n")

        # The app reads the bundle path through the steamAppPath default.
        app = home / "Applications" / "Steam.app"
        self.assertTrue((app / "Contents" / "MacOS" / "steam_osx").is_file())
        prefs = plistlib.loads(
            (home / "Library" / "Preferences" / f"{make_world.BUNDLE_ID}.plist").read_bytes())
        self.assertEqual(prefs["steamAppPath"], str(app))

        export = json.loads(
            (home / "Library/Application Support/Cartouche/steam-library.json").read_bytes())
        self.assertEqual(export["steamid"], make_world.STEAM_ID)
        self.assertEqual(len(export["apps"]), 8)

    # -- console files ------------------------------------------------------

    def test_medium_roms(self):
        home, _ = self.build("medium")
        roms = home / "Games" / "ROMs"

        # The Game Boy carts are byte-identical to the P13 fixtures: their
        # CRC32s are the recorded rows.
        expected = {"Cartouche Quest (World).gb": "0e8b3192",
                    "Cartouche Puzzle (World).gb": "0414d9d9",
                    "Cartouche Race (World).gb": "735c8190",
                    "Cartouche Maze (World).gb": "80d95fd0"}
        for name, crc in expected.items():
            data = (roms / "Game Boy" / name).read_bytes()
            self.assertEqual(len(data), 32768)
            self.assertEqual(f"{zlib.crc32(data):08x}", crc, name)

        cart = (roms / "Game Boy Advance" / "Cart Demo (World).gba").read_bytes()
        self.assertEqual(cart[0x04:0xA0], make_world.GBA_LOGO)
        self.assertEqual(cart[0xA0:0xA9], b"CART DEMO")
        self.assertEqual(cart[0xB2], 0x96)
        check = (-(0x19 + sum(cart[0xA0:0xBD]))) & 0xFF
        self.assertEqual(cart[0xBD], check)

        homebrew = (roms / "Super Nintendo" / "Cartouche Homebrew (World).sfc").read_bytes()
        self.assertEqual(f"{zlib.crc32(homebrew):08x}", "3fa862e9")
        self.assertEqual(homebrew[0x7FC0:0x7FD5], b"CARTOUCHE HOMEBREW   ")

        saga = roms / "PlayStation" / "Saga"
        self.assertEqual((saga / "Saga.m3u").read_text(),
                         "Saga (Disc 1).cue\nSaga (Disc 2).cue\n")
        track = (saga / "Saga (Disc 1).bin").read_bytes()
        self.assertEqual(len(track), 2352 * 26)
        self.assertIn(b"SLUS_999.02", track)
        self.assertTrue((roms / "mystery.iso").is_file())

        # The recorded rows are installed where ContentDatabase reads them.
        for system in make_world.SYSTEMS.values():
            rdb = home / "Library" / "Application Support" / "Cartouche" \
                / "retroarch" / "database" / f"{system}.rdb"
            self.assertTrue(rdb.read_bytes().startswith(b"RARCHDB\x00"), system)

    # -- the P6 installer set ------------------------------------------------

    def test_medium_installer(self):
        home, _ = self.build("medium")
        folder = home / "Downloads" / "Disco Elysium (Offline Installer) v1.0.4"
        self.assertTrue((folder / "setup.exe").read_bytes().startswith(b"MZ"))
        manifest = (folder / "MD5" / "checksums.md5").read_text()
        self.assertIn("selective", manifest)
        for part in ("data-01.bin", "data-02.bin"):
            md5 = hashlib.md5((folder / part).read_bytes()).hexdigest()
            self.assertIn(f"{md5} *..\\{part}", manifest)
        self.assertIn("data-03.bin", manifest)
        self.assertFalse((folder / "data-03.bin").exists())

    def test_medium_free_runner(self):
        # The 'one free runner ready' of the steam profile: the pinned build
        # installed with a receipt whose file hashes verify.
        home, _ = self.build("medium")
        root = home / "Library/Application Support/Cartouche/runners" \
            / "wine-wine-stable-11.0_1"
        receipt = json.loads((root / ".cartouche-runner.json").read_bytes())
        self.assertEqual(receipt["id"], "wine-stable-11.0_1")
        self.assertEqual(set(receipt["files"]),
                         {"bin/wine", "bin/wineserver",
                          "lib/wine/x86_64-windows/ntdll.dll",
                          "lib/wine/i386-windows/ntdll.dll",
                          "lib/wine/aarch64-windows/ntdll.dll"})
        for rel, want in receipt["files"].items():
            self.assertEqual(hashlib.sha256((root / rel).read_bytes()).hexdigest(), want, rel)
        self.assertTrue(os.access(root / "bin/wine", os.X_OK))

    # -- retro: the console state without the senior extras ----------------------

    def test_retro_consoles_no_runners(self):
        home, _ = self.build("retro")
        console = home / "Library/Application Support/Cartouche/retroarch"
        self.assertEqual(json.loads((console / "consoles.json").read_bytes()),
                         ["gb", "gba", "ps1", "snes"])
        games = json.loads((console / "library.json").read_bytes())
        self.assertEqual(len(games), 6)
        prefs = plistlib.loads(
            (home / "Library" / "Preferences" / f"{make_world.BUNDLE_ID}.plist").read_bytes())
        self.assertEqual(prefs["library.gameFolders"], [str(home / "Games" / "ROMs")])
        # Save states with a picture, named as SaveStates.list expects.
        states = console / "states" / "snes9x"
        self.assertTrue((states / "Cartouche Homebrew (World).state.auto").is_file())
        self.assertTrue((states / "Cartouche Homebrew (World).state1").is_file())
        self.assertTrue((states / "Cartouche Homebrew (World).state1.png")
                        .read_bytes().startswith(b"\x89PNG"))
        # No runner world: the senior-only installs stay absent, the free
        # Wine runner from the steam base remains.
        self.assertFalse((home / "Applications" / "CrossOver.app").exists())
        self.assertFalse((home / "Applications" / "Game Porting Toolkit.app").exists())
        self.assertFalse((home / "Applications" / "Dolphin.app").exists())
        runners = home / "Library/Application Support/Cartouche/runners"
        self.assertEqual([p.name for p in runners.iterdir()], ["wine-wine-stable-11.0_1"])

    # -- senior extras --------------------------------------------------------

    def test_senior_runners(self):
        home, _ = self.build("senior")

        bundle = home / "Applications" / "CrossOver.app"
        info = plistlib.loads((bundle / "Contents" / "Info.plist").read_bytes())
        self.assertEqual(info["CFBundleShortVersionString"], "26.3")
        wine = bundle / "Contents" / "SharedSupport" / "CrossOver" / "lib" / "wine"
        self.assertTrue(wine.is_dir())          # looksLikeCrossOver
        self.assertTrue((wine / "x86_64-unix" / "wine").is_file())

        gptk = home / "Applications" / "Game Porting Toolkit.app"
        framework = gptk / "Contents" / "Resources" / "wine" / "lib" / "external" \
            / "D3DMetal.framework"
        version = plistlib.loads(
            (framework / "Versions" / "A" / "Resources" / "Info.plist").read_bytes())
        self.assertEqual(version["CFBundleShortVersionString"], "3.0")
        self.assertEqual((framework / "Versions" / "Current").readlink().as_posix(), "A")

        # The copied runner verifies against its receipt.
        copied = home / "Library/Application Support/Cartouche/runners/gptk-3.0"
        receipt = json.loads((copied / ".cartouche-runner.json").read_bytes())
        self.assertEqual(receipt["version"], "3.0")
        for rel, want in receipt["files"].items():
            self.assertEqual(hashlib.sha256((copied / rel).read_bytes()).hexdigest(), want, rel)

        console = home / "Library/Application Support/Cartouche/retroarch"
        self.assertEqual(json.loads((console / "consoles.json").read_bytes()),
                         ["gb", "gba", "ps1", "snes"])
        records = json.loads((console / "cores.json").read_bytes())
        self.assertEqual(len(records), 4)
        for record in records:
            dylib = console / "cores" / record["file"]
            self.assertEqual(hashlib.sha256(dylib.read_bytes()).hexdigest(), record["sha256"])
            self.assertTrue(dylib.read_bytes().startswith(b"\xcf\xfa\xed\xfe"))
        games = json.loads((console / "library.json").read_bytes())
        self.assertEqual(len(games), 6)
        saga = next(g for g in games if g["console"] == "ps1")
        self.assertEqual(len(saga["discs"]), 2)
        prefs = plistlib.loads(
            (home / "Library" / "Preferences" / f"{make_world.BUNDLE_ID}.plist").read_bytes())
        self.assertEqual(prefs["library.gameFolders"], [str(home / "Games" / "ROMs")])

    def test_senior_dolphin(self):
        # The 'fake Dolphin.app' of the full profile, shaped for the detector.
        home, _ = self.build("senior")
        app = home / "Applications" / "Dolphin.app"
        info = plistlib.loads((app / "Contents" / "Info.plist").read_bytes())
        self.assertEqual(info["CFBundleIdentifier"], "org.dolphin-emu.dolphin")
        self.assertTrue(os.access(app / "Contents" / "MacOS" / "Dolphin", os.X_OK))
        # Medium worlds have no standalone emulators.
        home, _ = self.build("medium")
        self.assertFalse((home / "Applications" / "Dolphin.app").exists())

    def test_senior_healthy_by_default(self):
        # Without --damage a senior world is fully working: fresh compat cache,
        # no damaged runner clone.
        home, _ = self.build("senior")
        cache = home / "Library/Application Support/Cartouche" \
            / "compatibility" / "compat.json.gz"
        json.loads(gzip.decompress(cache.read_bytes()))
        self.assertFalse((home / "Library/Application Support/Cartouche/runners"
                          / "crossover-26.3.0.39832").exists())

    def test_stale_ages_the_compat_cache(self):
        # The offline profile: the cache stays valid but 'generated' is four
        # days back, so the banner reads 'data from N days ago', N > 3.
        home, _ = self.build("senior", stale=True)
        cache = home / "Library/Application Support/Cartouche" \
            / "compatibility" / "compat.json.gz"
        old = json.loads(gzip.decompress(cache.read_bytes()))["generated"]
        fresh = json.loads(gzip.decompress(make_world._compat_gz()))["generated"]
        self.assertNotEqual(old, fresh)
        want = datetime.datetime.fromtimestamp(
            make_world.NOW - 4 * make_world.DAY, datetime.timezone.utc)
        self.assertEqual(old, want.isoformat().replace("+00:00", "Z"))
        with self.assertRaises(ValueError):
            self.build("empty", stale=True)

    def test_damage_plants_the_broken_extras(self):
        home, _ = self.build("senior", damage=True)

        # The broken clone: lib/wine exists, no loader, no ntdll.
        broken = home / "Library/Application Support/Cartouche/runners" \
            / "crossover-26.3.0.39832" / "CrossOver"
        self.assertTrue((broken / "lib" / "wine").is_dir())
        self.assertFalse((broken / "lib" / "wine" / "x86_64-unix" / "wine").exists())

        # The corrupt cache is a damaged gzip the client must ignore.
        cache = home / "Library/Application Support/Cartouche" \
            / "compatibility" / "compat.json.gz"
        with self.assertRaises(Exception):
            gzip.decompress(cache.read_bytes())

        # damage is meaningless on a world with nothing in it
        with self.assertRaises(ValueError):
            self.build("empty", damage=True)

    # -- determinism -----------------------------------------------------------

    def test_deterministic(self):
        # Rebuilt into the same path (embedded paths stay identical), two runs
        # must produce byte-identical trees.
        import shutil
        with tempfile.TemporaryDirectory() as tmp:
            for profile in make_world.PROFILES:
                with self.subTest(profile=profile):
                    home = Path(tmp) / profile
                    make_world.build(home, profile)
                    first = tree_hash(home)
                    shutil.rmtree(home)
                    make_world.build(home, profile)
                    self.assertEqual(first, tree_hash(home))


if __name__ == "__main__":
    unittest.main()
