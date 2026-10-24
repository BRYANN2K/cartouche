"""Build compat.json.gz from AppleGamingWiki, ProtonDB and AreWeAntiCheatYet.

    python3 tools/compat/build_compat.py --out compat.json.gz \\
        [--previous last/compat.json.gz] [--cache DIR] [--fixtures DIR] [--only 1245620,730]

--previous is the file published the night before. A source that does not
answer keeps its records from it, with their old dates. --fixtures replays
recorded answers instead of using the network. Exits 1 when the file cannot be
built or does not match docs/schema/compat.schema.json.
"""

import argparse
import datetime
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from compatdata import build, cache, http, replay  # noqa: E402


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", required=True, help="where to write compat.json.gz")
    parser.add_argument("--json", help="also write the uncompressed file here")
    parser.add_argument("--previous", help="the previously published compat.json.gz")
    parser.add_argument("--cache", help="a folder kept between runs")
    parser.add_argument("--fixtures", help="replay recorded answers from this folder")
    parser.add_argument("--down", default="", help="with --fixtures: sources to treat as down")
    parser.add_argument("--only", help="comma separated Steam App IDs to keep")
    parser.add_argument("--now", help="the build time, ISO 8601 (default: now)")
    args = parser.parse_args(argv)

    now = (datetime.datetime.fromisoformat(args.now.replace("Z", "+00:00")) if args.now
           else datetime.datetime.now(datetime.timezone.utc))
    if args.fixtures:
        fetcher = replay.FixtureFetcher(args.fixtures, down=[s for s in args.down.split(",") if s])
    else:
        fetcher = http.Fetcher()
    store = cache.Cache(args.cache)
    only = {s.strip() for s in args.only.split(",")} if args.only else None
    try:
        previous = build.load_previous(args.previous)
        document = build.build(fetcher, store, now, previous=previous, only=only)
        raw, packed = build.encode(document)
    except build.BuildFailed as error:
        print(f"build_compat: {error}", file=sys.stderr)
        return 1

    out = pathlib.Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(packed)
    if args.json:
        pathlib.Path(args.json).write_bytes(raw)
    removed = store.prune()
    requests = fetcher.requests if isinstance(fetcher.requests, int) else len(fetcher.requests)
    for key, source in document["sources"].items():
        print(f"{key}: {source['status']}, {source['fetched']}")
    print(f"{len(document['records'])} records, generated {document['generated']}, "
          f"{len(packed)} bytes gzip ({len(raw)} raw), {requests} requests, "
          f"cache {store.hits} hits {store.misses} misses {removed} pruned")
    return 0


if __name__ == "__main__":
    sys.exit(main())
