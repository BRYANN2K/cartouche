#!/usr/bin/env python3
import json
from pathlib import Path
root = Path(__file__).resolve().parents[1] / 'feats'
source = (root / 'steaminstall.js').read_text()
(root / 'steaminstall.h').write_text('// Generated from steaminstall.js by dylib/tests/embed-steaminstall.py.\n#define NP_STEAM_INSTALL \\\n' + ''.join('    ' + json.dumps(line) + ' \\\n' for line in source.splitlines()) + '    ""\n')
