# Builds a held-out test set from a wincap stream: whole frames at the network's 512x256, triplets
# (i, i+k, i+2k), as sintel.npy. Kept out of training (OpenTTD).
# Usage: heldout.py <out.npy> <width> <height> <count> [k] < wincap stream
import sys, numpy as np
from PIL import Image

out, w, h, count = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
k = int(sys.argv[5]) if len(sys.argv) > 5 else 1
size = w * h * 4 + 8
frames, kept, i = [], [], 0
while len(kept) < count:
	buf = sys.stdin.buffer.read(size)
	if len(buf) < size:
		break
	t = np.frombuffer(buf[:8], np.float64)[0]
	img = np.frombuffer(buf, np.uint8, offset=8).reshape(h, w, 4)[..., 2::-1]
	frames = (frames + [(t, np.asarray(Image.fromarray(img).resize((512, 256), Image.BILINEAR, reducing_gap=2.0)))])[-(2 * k + 1):]
	i += 1
	if len(frames) < 2 * k + 1 or i % 15:
		continue
	(ta, a), (tm, m), (tb, b) = frames[0], frames[k], frames[2 * k]
	d = lambda x, y: np.abs(x.astype(np.int16) - y).mean()
	if abs((tm - ta) - (tb - tm)) < 0.004 * k and d(a, b) > 0.3 and d(a, m) > 0.02 and d(m, b) > 0.02 and d(a, b) < 40:
		kept.append(np.stack([a, m, b]))
np.save(out, np.stack(kept) if kept else np.zeros((0, 3, 256, 512, 3), np.uint8))
print("held-out", out, len(kept))
