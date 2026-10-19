"""Tests for packaging/wine-crossover: the pinned fetch, the package and its checks.

The real build needs an x86_64 Mac and an hour, so it runs only in CI. These run
the same scripts on a fake install tree in a temporary folder.
"""
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "packaging" / "wine-crossover"
sys.path.insert(0, str(SCRIPTS))
import manifest_entry  # noqa: E402


def sha256(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


def run(*args, env=None, check=False):
    return subprocess.run([str(a) for a in args], capture_output=True, text=True, env=env, check=check)


def write(path, text, mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(mode)


@unittest.skipUnless(sys.platform == "darwin", "the scripts use macOS tools")
class WineCrossOverScripts(unittest.TestCase):

    def setUp(self):
        self.work = pathlib.Path(tempfile.mkdtemp(prefix="wine-crossover-test-"))
        self.addCleanup(shutil.rmtree, self.work)

    # A source tarball with the notices package.sh copies, and pins that name it
    def fake_sources(self):
        src = self.work / "srcroot"
        for name in ("LICENSE", "COPYING.LIB", "AUTHORS"):
            write(src / "sources" / "wine" / name, f"{name} of the fake sources\n")
        tarball = self.work / "crossover-sources-26.3.0.tar.gz"
        run("tar", "-czf", tarball, "-C", src, "sources", check=True)
        pins = (SCRIPTS / "pins.env").read_text().replace(
            "CX_SOURCE_SHA256=ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872",
            f"CX_SOURCE_SHA256={sha256(tarball)}")
        self.assertIn(sha256(tarball), pins)
        pins_file = self.work / "pins.env"
        pins_file.write_text(pins)
        return tarball, pins_file

    # What make install-lib leaves, with a shell script standing in for wine
    def fake_install(self, version="wine-11.0 (fake)"):
        install = self.work / "install"
        wine = f"#!/bin/sh\n[ \"$1\" = --version ] && echo '{version}'\n"
        write(install / "lib/wine/x86_64-unix/wine", wine, 0o755)
        (install / "bin").mkdir(parents=True)
        os.symlink("../lib/wine/x86_64-unix/wine", install / "bin/wine")
        write(install / "bin/wineserver", "#!/bin/sh\n", 0o755)
        write(install / "share/wine/wine.inf", "[Version]\n")
        for arch in ("x86_64-windows", "i386-windows"):
            write(install / "lib/wine" / arch / "ntdll.dll", f"MZ {arch}\n")
        return install

    def package(self):
        tarball, pins = self.fake_sources()
        install = self.fake_install()
        out = self.work / "out"
        env = dict(os.environ, PINS_FILE=str(pins), REPOSITORY="owner/repo", GITHUB_SHA="abc123")
        r = run("sh", SCRIPTS / "package.sh", install, tarball, out, env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        return out

    def test_fetch_keeps_a_matching_file(self):
        served = self.work / "served.bin"
        served.write_bytes(b"pinned bytes")
        dest = self.work / "downloads" / "file.bin"
        r = run("sh", SCRIPTS / "fetch.sh", served.as_uri(), sha256(served), dest)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(dest.read_bytes(), b"pinned bytes")
        r = run("sh", SCRIPTS / "fetch.sh", "file:///nonexistent", sha256(served), dest)
        self.assertEqual(r.returncode, 0, "a file that already matches is reused without fetching")

    def test_fetch_refuses_a_wrong_hash_and_keeps_nothing(self):
        served = self.work / "served.bin"
        served.write_bytes(b"substituted bytes")
        dest = self.work / "downloads" / "file.bin"
        r = run("sh", SCRIPTS / "fetch.sh", served.as_uri(), "0" * 64, dest)
        self.assertEqual(r.returncode, 1)
        self.assertIn("the pin is", r.stderr)
        self.assertEqual(list((self.work / "downloads").iterdir()), [])

    def test_package_has_the_notices_source_offer_and_a_matching_entry(self):
        out = self.package()
        asset = out / "wine-crossover-26.3.0-1-x86_64.tar.xz"
        self.assertTrue(asset.is_file())
        self.assertEqual((out / "tag").read_text().strip(), "wine-crossover-26.3.0-1")
        self.assertEqual((out / f"{asset.name}.sha256").read_text().split()[0], sha256(asset))

        listing = run("tar", "-tJf", asset, check=True).stdout.split()
        self.assertTrue(all(p.startswith("wine-crossover-26.3.0-1") for p in listing))
        for f in ("LICENSE", "COPYING.LIB", "AUTHORS", "SOURCE.md", "BUILDINFO.txt", "bin/wine",
                  "lib/wine/x86_64-unix/wine", "lib/wine/i386-windows/ntdll.dll"):
            self.assertIn(f"wine-crossover-26.3.0-1/{f}", listing)
        offer = run("tar", "-xJOf", asset, "wine-crossover-26.3.0-1/SOURCE.md", check=True).stdout
        self.assertIn("https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.3.0.tar.gz", offer)
        self.assertIn("https://github.com/owner/repo/releases/tag/wine-crossover-26.3.0-1", offer)
        self.assertIn("tree/abc123/packaging/wine-crossover", offer)
        self.assertIn("Lesser General Public", offer)

        entry = json.loads((out / "manifest-entry.json").read_text())
        self.assertEqual(entry, {
            "id": "wine-crossover-26.3.0-1", "kind": "wineBuild", "origin": "cartouche",
            "name": "Wine CrossOver", "version": "26.3.0", "displayVersion": "26.3",
            "url": "https://github.com/owner/repo/releases/download/wine-crossover-26.3.0-1/"
                   "wine-crossover-26.3.0-1-x86_64.tar.xz",
            "size": asset.stat().st_size, "sha256": sha256(asset),
            "root": "wine-crossover-26.3.0-1", "loader": "bin/wine", "flavors": ["rosetta"],
        })

    def test_package_refuses_sources_that_are_not_the_pinned_tarball(self):
        _, pins = self.fake_sources()
        other = self.work / "other.tar.gz"
        other.write_bytes(b"not the tarball")
        env = dict(os.environ, PINS_FILE=str(pins))
        r = run("sh", SCRIPTS / "package.sh", self.fake_install(), other, self.work / "out", env=env)
        self.assertEqual(r.returncode, 1)
        self.assertIn("not the pinned source tarball", r.stderr)

    def test_verify_runs_wine_from_the_archive(self):
        out = self.package()
        r = run("sh", SCRIPTS / "verify.sh", out / "wine-crossover-26.3.0-1-x86_64.tar.xz")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip().splitlines()[-1], "wine-11.0 (fake)")

    def test_verify_refuses_an_archive_that_does_not_match_its_hash(self):
        out = self.package()
        asset = out / "wine-crossover-26.3.0-1-x86_64.tar.xz"
        (out / f"{asset.name}.sha256").write_text(f"{'0' * 64}  {asset.name}\n")
        r = run("sh", SCRIPTS / "verify.sh", asset)
        self.assertEqual(r.returncode, 1)
        self.assertIn("has SHA-256", r.stderr)

    # Two real dylibs, one loading the other by an absolute path as Homebrew's do
    def dylibs(self):
        lib = self.work / "cellar"
        lib.mkdir()
        (self.work / "foo.c").write_text("int foo(void) { return 1; }\n")
        (self.work / "bar.c").write_text("int foo(void); int bar(void) { return foo(); }\n")
        run("cc", "-dynamiclib", "-o", lib / "libfoo.1.dylib", "-install_name", lib / "libfoo.1.dylib",
            self.work / "foo.c", check=True)
        run("cc", "-dynamiclib", "-o", lib / "libbar.2.dylib", "-install_name", lib / "libbar.2.dylib",
            self.work / "bar.c", lib / "libfoo.1.dylib", "-Wl,-headerpad_max_install_names", check=True)
        return lib

    def test_check_deps_catches_a_library_outside_the_package(self):
        lib = self.dylibs()
        r = run("sh", SCRIPTS / "check-deps.sh", lib)
        self.assertEqual(r.returncode, 1)
        self.assertIn(f"loads {lib}/libfoo.1.dylib", r.stderr)

    def test_bundle_deps_copies_dependencies_and_names_them_through_rpath(self):
        lib = self.dylibs()
        bundled = self.work / "deps"
        r = run("sh", SCRIPTS / "bundle-deps.sh", bundled, lib / "libbar.2.dylib")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(sorted(p.name for p in bundled.iterdir()), ["libbar.2.dylib", "libfoo.1.dylib"])
        loads = run("otool", "-L", bundled / "libbar.2.dylib", check=True).stdout
        self.assertIn("@rpath/libbar.2.dylib", loads)
        self.assertIn("@rpath/libfoo.1.dylib", loads)
        self.assertNotIn(str(lib), loads)
        r = run("sh", SCRIPTS / "check-deps.sh", bundled)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_dry_run_prints_the_pinned_configure_and_touches_nothing(self):
        work = self.work / "dry"
        r = run("sh", SCRIPTS / "build.sh", "--dry-run", work)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(work.exists())
        self.assertIn("crossover-sources-26.3.0.tar.gz", r.stdout)
        configure = next(line for line in r.stdout.splitlines() if "sources/wine/configure" in line)
        for flag in ("--enable-archs=i386,x86_64", "--with-mingw", "--without-x", "--disable-tests",
                     "-Wl,-rpath,@loader_path/../../", "-mmacosx-version-min=15.0"):
            self.assertIn(flag, configure)
        self.assertIn("make install-lib", r.stdout)
        self.assertIn("check-deps.sh", r.stdout)


class ManifestEntry(unittest.TestCase):

    def test_url_must_be_https_and_name_the_archive(self):
        with tempfile.NamedTemporaryFile(suffix=".tar.xz") as f:
            name = pathlib.Path(f.name).name
            kw = dict(id="x", root="x", name="Wine CrossOver", version="26.3.0", display_version="26.3",
                      origin="cartouche")
            self.assertEqual(manifest_entry.entry(f.name, url=f"https://h/{name}", **kw)["size"], 0)
            with self.assertRaises(SystemExit):
                manifest_entry.entry(f.name, url=f"http://h/{name}", **kw)
            with self.assertRaises(SystemExit):
                manifest_entry.entry(f.name, url="https://h/other.tar.xz", **kw)


class Pins(unittest.TestCase):

    def test_pins_are_full_hashes_and_https(self):
        pins = dict(line.split("=", 1) for line in (SCRIPTS / "pins.env").read_text().splitlines()
                    if line and not line.startswith("#"))
        for key in ("CX_SOURCE_SHA256", "LLVM_MINGW_SHA256"):
            self.assertRegex(pins[key], r"^[0-9a-f]{64}$")
        for key in ("CX_SOURCE_URL", "LLVM_MINGW_URL"):
            self.assertTrue(pins[key].startswith("https://"))
        self.assertTrue(pins["CX_SOURCE_URL"].endswith(f"crossover-sources-{pins['CX_VERSION']}.tar.gz"))


if __name__ == "__main__":
    unittest.main()
