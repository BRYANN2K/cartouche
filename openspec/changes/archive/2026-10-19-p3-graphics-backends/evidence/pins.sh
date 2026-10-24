#!/bin/sh
# Prints what GitHub says about the pinned DXMT and DXVK-macOS releases
rel() {
  curl -s "https://api.github.com/repos/$1/releases/$2" | python3 -I -c 'import json,sys; r=json.load(sys.stdin); print(r["tag_name"], r["published_at"]); [print(" ", a["name"], a["size"], a.get("digest")) for a in r["assets"]]'
}
echo "# GitHub REST API and raw files, checked $(date -u +%Y-%m-%d)"
echo "\$ api.github.com/repos/3Shain/dxmt/releases/latest"
rel 3Shain/dxmt latest
echo "\$ api.github.com/repos/Gcenx/DXVK-macOS/releases/latest"
rel Gcenx/DXVK-macOS latest
echo "\$ raw.githubusercontent.com/3Shain/dxmt/v0.80/LICENSE, line 1"
curl -s https://raw.githubusercontent.com/3Shain/dxmt/v0.80/LICENSE | head -1
echo "\$ raw.githubusercontent.com/Gcenx/DXVK-macOS/v1.10.3-20230507-repack/LICENSE, line 4"
curl -s https://raw.githubusercontent.com/Gcenx/DXVK-macOS/v1.10.3-20230507-repack/LICENSE | sed -n 4p
