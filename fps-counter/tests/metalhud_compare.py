# Frame intervals from the Metal HUD's "metal-HUD:" log lines against the stand-in game's presentedTime.
#   python3 metalhud_compare.py <log stream output or stderr> <game times, or /dev/null>
# A line is: first frame number, graphics memory, process memory, then per frame its present
# interval and GPU time.
import re
import sys


def low1(d):
    d = sorted(d, reverse=True)
    slow = d[:max(1, len(d) // 100)]
    return len(slow) / sum(slow) if slow else 0.0


frames, intervals, gpu = [], [], []
for line in open(sys.argv[1], errors="replace"):
    m = re.search(r"metal-HUD:\s*([-0-9.,eE ]+)", line)
    if not m:
        continue
    v = [float(x) for x in m.group(1).replace(" ", "").split(",") if x]
    if len(v) < 5:
        continue
    frames.append(int(v[0]))
    intervals += v[3::2]
    gpu += v[4::2]
game = sorted(float(x) for x in open(sys.argv[2]) if x.strip())
gd = [b - a for a, b in zip(game, game[1:])]
unit = 1000.0 if intervals and sorted(intervals)[len(intervals) // 2] > 1 else 1.0
iv = [x / unit for x in intervals if x > 0]
print(f"hud lines {len(frames)} frames {len(intervals)} mean {len(iv) / sum(iv) if iv else 0:.2f} fps 1%low {low1(iv):.2f} "
      f"gpu median {sorted(gpu)[len(gpu) // 2] if gpu else 0:.3f}  |  game {len(game)} frames mean {len(gd) / sum(gd) if gd else 0:.2f} fps 1%low {low1(gd):.2f}")
