"""Build the bundled multiplayer counts from ProtonDB's official monthly export.

python3 tools/compat/build_protondb.py --out app/Sources/NotProtonApp/Resources/protondb-online.json --cache .scratch/protondb-cache
"""

import argparse
import datetime
import json
from pathlib import Path

from compatdata import cache, http
from compatdata.sources import protondb


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True)
    parser.add_argument("--cache")
    args = parser.parse_args()
    result = protondb.fetch(http.Fetcher(), cache.Cache(args.cache), datetime.date.today().isoformat())
    records = {app: block for app, block in result.blocks.items() if block["online_tried"] > 0}
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(records, sort_keys=True, separators=(",", ":")) + "\n")
    print(f"{len(records)} games from {result.meta['export']}; ODbL 1.0")


if __name__ == "__main__":
    main()
