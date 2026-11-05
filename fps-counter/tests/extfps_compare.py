# Compares extfps's frame times with the stand-in game's own presentedTime list, on the span both cover.
#   python3 extfps_compare.py <game times> <extfps times>
import sys


def load(path):
    with open(path) as f:
        return sorted(float(x) for x in f if x.strip())


def low1(t):
    d = sorted((b - a for a, b in zip(t, t[1:])), reverse=True)
    if not d:
        return 0.0
    slow = d[:max(1, len(d) // 100)]
    return len(slow) / sum(slow)


def rate(t):
    return (len(t) - 1) / (t[-1] - t[0]) if len(t) > 1 else 0.0


game, ext = load(sys.argv[1]), load(sys.argv[2])
lo, hi = max(game[0], ext[0]) + 0.5, min(game[-1], ext[-1]) - 0.5
g = [x for x in game if lo <= x <= hi]
e = [x for x in ext if lo <= x <= hi]
offsets, j = [], 0
for x in g:
    while j + 1 < len(e) and abs(e[j + 1] - x) <= abs(e[j] - x):
        j += 1
    if e:
        offsets.append(e[j] - x)
med = sorted(offsets)[len(offsets) // 2] if offsets else 0
matched = sum(1 for o in offsets if abs(o - med) < 0.002)
print(f"span {hi - lo:.1f} s  game {len(g)} frames {rate(g):.2f} fps 1%low {low1(g):.2f}  "
      f"extfps {len(e)} frames {rate(e):.2f} fps 1%low {low1(e):.2f}  "
      f"matched<2ms of median offset {100 * matched / max(1, len(g)):.1f}%  offset median {med * 1000:+.2f} ms")
