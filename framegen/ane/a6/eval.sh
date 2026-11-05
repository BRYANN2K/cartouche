#!/bin/sh
# Scores a flow network the way A4 scored RIFE lean: its synthesis alone, then its vectors through
# MetalFX and the repair pass in tune (TUNE_MOTION), on pairs exported once by TUNE_PAIRS.
# Usage: eval.sh <checkpoint.pt | model.mlpackage> <pairs dir>   (from the repository root, tune built)
set -e
here=$(dirname "$0")
python=${FRAMEGEN_PYTHON:-/tmp/fgtool/venv/bin/python}
case "$1" in
*.pt) package=${1%.pt}.mlpackage; "$python" "$here/convert.py" "$1" "$package" | grep saved ;;
*) package=$1 ;;
esac
"$python" "$here/score.py" "$2" "$package" 2>&1 | grep fps
TUNE_MOTION=$2 TUNE_SET="zero=0" out/framegen/tune --3d mockup/brand/cartouche-icon-default.svg 72 40 | tail -1
