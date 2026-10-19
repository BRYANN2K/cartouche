"""What the builder keeps between nightly runs, so unchanged games are not fetched again.

Keys name a version of the thing (a page revision, a lastModified time, an
export name), so an entry never goes stale. Entries a run did not use are
removed at the end of it.
"""

import json
import os
import pathlib
import re


class Cache:
    def __init__(self, root=None):
        self.root = pathlib.Path(root) if root else None
        self.used = set()
        self.hits = 0
        self.misses = 0

    def _path(self, key):
        safe = re.sub(r"[^A-Za-z0-9._/-]", "_", key)
        return self.root / f"{safe}.json"

    def get(self, key):
        if not self.root:
            self.misses += 1
            return None
        path = self._path(key)
        self.used.add(path)
        try:
            value = json.loads(path.read_text())
        except (OSError, ValueError):
            self.misses += 1
            return None
        self.hits += 1
        return value

    def put(self, key, value):
        if not self.root:
            return
        path = self._path(key)
        path.parent.mkdir(parents=True, exist_ok=True)
        # One name per process, so two builds sharing a cache cannot collide
        temp = path.with_suffix(f".{os.getpid()}.tmp")
        temp.write_text(json.dumps(value, separators=(",", ":")))
        temp.replace(path)
        self.used.add(path)

    def prune(self):
        if not self.root or not self.root.exists():
            return 0
        removed = 0
        for path in self.root.rglob("*.json"):
            if path not in self.used:
                path.unlink()
                removed += 1
        return removed
