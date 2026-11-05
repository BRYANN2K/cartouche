# Scores RIFE's own synthesis (two warps blended by its mask) on frame pairs dumped by
# tune --3d with TUNE_PAIRS, with the same ghost metrics as tune.
# Usage: score.py <pairs dir> <model.mlpackage> [label]
import glob, sys, numpy as np, coremltools as ct

pairs, package = sys.argv[1], sys.argv[2]
W, H, MW, MH = 1280, 300, 512, 256
model = ct.models.MLModel(package, compute_units=ct.ComputeUnit.CPU_AND_NE)

def load(path):
    return np.fromfile(path, np.uint8).reshape(H, W, 4)[:, :, 2::-1].astype(np.float32) / 255  # BGRA -> RGB

def resize(img, h, w):
    ys = (np.arange(h) + 0.5) * img.shape[0] / h - 0.5
    xs = (np.arange(w) + 0.5) * img.shape[1] / w - 0.5
    return sample(img, np.broadcast_to(xs, (h, w)), np.broadcast_to(ys[:, None], (h, w)))

def sample(img, x, y):
    x = np.clip(x, 0, img.shape[1] - 1); y = np.clip(y, 0, img.shape[0] - 1)
    x0 = np.floor(x).astype(int); y0 = np.floor(y).astype(int)
    x1 = np.minimum(x0 + 1, img.shape[1] - 1); y1 = np.minimum(y0 + 1, img.shape[0] - 1)
    fx = (x - x0)[..., None]; fy = (y - y0)[..., None]
    top = img[y0, x0] * (1 - fx) + img[y0, x1] * fx
    bottom = img[y1, x0] * (1 - fx) + img[y1, x1] * fx
    return top * (1 - fy) + bottom * fy

def score(out, truth):
    e = np.abs(out * 255 - truth * 255).max(axis=2)
    ghost = 100 * (e > 24).mean()
    co = lambda a: a[:H // 2 * 2, :W // 2 * 2].reshape(H // 2, 2, W // 2, 2, 3).mean(axis=(1, 3))
    coarse = 100 * (np.abs(co(out) * 255 - co(truth) * 255).max(axis=2) > 24).mean()
    return e.mean(), ghost, coarse

for fps in ("72", "40"):
    rows = {"rife": [], "rife+still": [], "ours": []}
    for prev_path in sorted(glob.glob(f"{pairs}/{fps}fps_*_prev.raw")):
        base = prev_path[:-len("prev.raw")]
        prev, cur, truth, ours = (load(base + n + ".raw") for n in ("prev", "cur", "truth", "ours"))
        inputs = {k: resize(v, MH, MW).transpose(2, 0, 1)[None].astype(np.float32) for k, v in (("a", prev), ("b", cur))}
        result = model.predict(inputs)
        flow, mask = result["flow"][0], result["mask"][0, 0]
        up = lambda c: resize(c[..., None], H, W)[..., 0]
        fx0, fy0 = up(flow[0]) * W / MW, up(flow[1]) * H / MH
        fx1, fy1 = up(flow[2]) * W / MW, up(flow[3]) * H / MH
        m = up(mask)[..., None]
        gx, gy = np.meshgrid(np.arange(W, dtype=np.float32), np.arange(H, dtype=np.float32))
        out = m * sample(prev, gx + fx0, gy + fy0) + (1 - m) * sample(cur, gx + fx1, gy + fy1)
        rows["rife"].append(score(out, truth))
        # MetalFX's motion: from a pixel of the current frame to where it was, at that pixel. The
        # middle-frame point that lands on c is near c - F_t1(c): read both flows there.
        mx, my = gx - fx1, gy - fy1
        vx = sample(np.stack([fx0, fx1], -1), mx, my); vy = sample(np.stack([fy0, fy1], -1), mx, my)
        motion = np.stack([vx[..., 0] - vx[..., 1], vy[..., 0] - vy[..., 1]], -1).astype(np.float16)
        motion.tofile(base + "rifemotion.raw")
        still = (np.abs(prev - cur).max(axis=2) < 1.5 / 255)[..., None]
        rows["rife+still"].append(score(np.where(still, cur, out), truth))
        rows["ours"].append(score(ours, truth))
    for k, v in rows.items():
        v = np.array(v)
        print(f"{fps} fps {k:<11} err {v[:,0].mean():5.2f}  ghost% {v[:,1].mean():5.2f}  2x2% {v[:,2].mean():5.2f}  ({len(v)} frames)")
