# Scores Core ML flow networks (RIFE lean's interface) on held-out triplet sets at 512x256, synthesis
# alone (two warps and the mask), as A6 scored Sintel: mean error in levels and 2x2 blocks off by > 24.
# Usage: score_set.py <set.npy>[,<set.npy>...] <label>=<model.mlpackage> ...
import os, sys, numpy as np, coremltools as ct


def sample(img, x, y):
	h, w = img.shape[:2]
	x = np.clip(x, 0, w - 1); y = np.clip(y, 0, h - 1)
	x0 = np.floor(x).astype(int); y0 = np.floor(y).astype(int)
	x1 = np.minimum(x0 + 1, w - 1); y1 = np.minimum(y0 + 1, h - 1)
	fx = (x - x0)[..., None]; fy = (y - y0)[..., None]
	return (img[y0, x0] * (1 - fx) + img[y0, x1] * fx) * (1 - fy) + (img[y1, x0] * (1 - fx) + img[y1, x1] * fx) * fy


def score(model, triplets):
	errs, wrongs = [], []
	for a, m, b in triplets:
		a, m, b = (f.astype(np.float32) / 255 for f in (a, m, b))
		out = model.predict({"a": a.transpose(2, 0, 1)[None], "b": b.transpose(2, 0, 1)[None]})
		flow, mask = out["flow"][0], out["mask"][0, 0][..., None]
		h, w = a.shape[:2]
		gx, gy = np.meshgrid(np.arange(w, dtype=np.float32), np.arange(h, dtype=np.float32))
		synth = mask * sample(a, gx + flow[0], gy + flow[1]) + (1 - mask) * sample(b, gx + flow[2], gy + flow[3])
		errs.append(np.abs(synth - m).mean() * 255)
		co = lambda x: x.reshape(h // 2, 2, w // 2, 2, 3).mean(axis=(1, 3))
		wrongs.append(100 * (np.abs(co(synth) - co(m)).max(axis=2) * 255 > 24).mean())
	return np.mean(errs), np.mean(wrongs)


sets = sys.argv[1].split(",")
models = [arg.split("=", 1) for arg in sys.argv[2:]]
print("| Set | Triplets | " + " | ".join(f"{label} err | {label} 2x2%" for label, _ in models) + " |")
print("|---|---:|" + "---:|---:|" * len(models))
loaded = [(label, ct.models.MLModel(path, compute_units=ct.ComputeUnit.CPU_AND_NE)) for label, path in models]
for path in sets:
	data = np.load(path, mmap_mode="r")
	cells = []
	for label, model in loaded:
		e, w = score(model, data)
		cells += [f"{e:.2f}", f"{w:.2f}"]
	print(f"| {os.path.basename(path)[:-4]} | {len(data)} | " + " | ".join(cells) + " |", flush=True)
