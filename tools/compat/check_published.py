"""Check a built compat.json.gz before it is published.

    python3 tools/compat/check_published.py compat.json.gz [--night 2026-10-19] [--reference]

Fails when the file is over 25 MB, is not gzip JSON, does not match
docs/schema/compat.schema.json, names MacGamingDB anywhere, or was not
generated on --night (UTC).
--reference also validates with the jsonschema package, which CI installs, so
the builder's own validator is checked against a complete one.
"""

import argparse
import gzip
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from compatdata import build, schema  # noqa: E402


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("file")
    parser.add_argument("--night", help="the UTC date the file must be generated on")
    parser.add_argument("--reference", action="store_true", help="also validate with jsonschema")
    args = parser.parse_args(argv)

    packed = pathlib.Path(args.file).read_bytes()
    problems = []
    if len(packed) > build.MAX_BYTES:
        problems.append(f"{len(packed)} bytes, over {build.MAX_BYTES}")
    raw = gzip.decompress(packed)
    # MacGamingDB publishes no data license, so nothing of it may be published
    if b"macgamingdb" in raw.lower():
        problems.append("the file names MacGamingDB, whose data must not be published")
    document = json.loads(raw)
    rules = schema.load()
    problems += schema.errors(document, rules)
    if args.reference:
        import jsonschema
        validator = jsonschema.Draft202012Validator(
            rules, format_checker=jsonschema.Draft202012Validator.FORMAT_CHECKER)
        problems += [f"jsonschema: {e.json_path}: {e.message}" for e in validator.iter_errors(document)]
    if args.night and not document.get("generated", "").startswith(args.night):
        problems.append(f"generated {document.get('generated')}, not on {args.night}")
    if problems:
        print("check_published: " + "\n  ".join(problems[:30]), file=sys.stderr)
        return 1
    stale = [k for k, s in document["sources"].items() if s["status"] == "stale"]
    print(f"{args.file}: {len(packed)} bytes, {len(document['records'])} records, "
          f"generated {document['generated']}, schema valid"
          + (f", stale: {', '.join(stale)}" if stale else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
