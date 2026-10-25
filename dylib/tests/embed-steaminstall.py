#!/usr/bin/env python3
import json
from pathlib import Path
root = Path(__file__).resolve().parents[1] / 'feats'
source = (root / 'steaminstall.js').read_text()
# The lines are joined into one in Steam's page, so a // comment would swallow the rest of the worker
bad = [n for n, line in enumerate(source.splitlines(), 1) if '//' in line.split("'")[0].split('"')[0] and 'https://' not in line]
if bad: raise SystemExit(f'steaminstall.js: // comment on line {bad}; use /* */')
(root / 'steaminstall.h').write_text('// Generated from steaminstall.js by dylib/tests/embed-steaminstall.py.\n#define NP_STEAM_INSTALL \\\n' + ''.join('    ' + json.dumps(line) + ' \\\n' for line in source.splitlines()) + '    ""\n')
