#!/usr/bin/env python3
"""Stage the checked CI bundle for this exact release commit from the Mac cache."""
import argparse
import hashlib
import json
import pathlib
import shutil
import subprocess
import tempfile


def verified_archive(folder, commit):
    metadata = json.loads((folder / "provenance.json").read_text())
    if metadata.get("head_sha") != commit or metadata.get("conclusion") != "success":
        raise ValueError("CI provenance must name this exact commit and a successful run")
    archive = folder / "Cartouche.zip"
    with archive.open("rb") as contents:
        digest = hashlib.file_digest(contents, "sha256").hexdigest()
    if digest != metadata.get("sha256"):
        raise ValueError("CI bundle checksum does not match its provenance")
    return archive


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folder", type=pathlib.Path)
    parser.add_argument("commit")
    parser.add_argument("output", type=pathlib.Path)
    args = parser.parse_args()
    archive = verified_archive(args.folder, args.commit)
    with tempfile.TemporaryDirectory() as work:
        subprocess.run(["ditto", "-x", "-k", str(archive), work], check=True)
        app = pathlib.Path(work) / "Cartouche.app"
        subprocess.run(["codesign", "--verify", "--strict", "--deep", str(app)], check=True)
        if args.output.exists():
            shutil.rmtree(args.output)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["ditto", str(app), str(args.output)], check=True)
    print(f"Staged successful CI bundle for {args.commit}")


if __name__ == "__main__":
    main()
