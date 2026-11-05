# Trains A6Flow on the GPU (PyTorch, MPS) against the true middle frame, with Practical-RIFE 4.25.lite
# (code and weights MIT) as a teacher for the flows and the mask where it reconstructs better.
# Usage: train.py <run dir> <hours> [--smoke] [--init <checkpoint>] [--fg2 <dataset dir>] [--segment]
# Data, all in ~/Downloads/fg-tests/a6 (see make_data.py): data3d.npy, databbb.npy, logo.png.
# --init fine-tunes a checkpoint (FG 1 to FG 2) at a lower rate; --fg2 mixes in the samples of
# fg2/triplets.py, those without a true middle taught by RIFE alone; --segment stops after the next
# checkpoint, so a caller can hand the GPU over between segments and resume.
import importlib.util, io, math, os, random, sys, time, types, zipfile
import numpy as np, torch, torch.nn.functional as F
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from model import A6Flow

RUN, HOURS = sys.argv[1], float(sys.argv[2])
SMOKE = "--smoke" in sys.argv
SEGMENT = "--segment" in sys.argv
arg = lambda name: sys.argv[sys.argv.index(name) + 1] if name in sys.argv else None
INIT, FG2 = arg("--init"), arg("--fg2")
PEAK, FLOOR = (1e-4, 1e-6) if INIT else (3e-4, 1e-5)
DATA = os.path.expanduser(os.environ.get("A6_DATA", "~/Downloads/fg-tests/a6"))
RIFE_LOG = os.path.expanduser(os.environ.get("RIFE_LOG", "~/Downloads/fg-tests/rife-425lite/train_log"))
RIFE_REPO = os.path.expanduser(os.environ.get("RIFE_REPO", "~/Downloads/fg-tests/rife-src/repo"))
CHANNELS = (24, 48, 64, 96, 128)
W, H, BATCH = 512, 256, 8
dev = torch.device("mps")
os.makedirs(RUN, exist_ok=True)
torch.manual_seed(6)
random.seed(6)
log = open(f"{RUN}/train.log", "a")


def say(*parts):
    line = " ".join(str(p) for p in parts)
    print(line, flush=True)
    log.write(line + "\n")
    log.flush()


def grid(n, h, w):
    gy, gx = torch.meshgrid(torch.arange(h, device=dev, dtype=torch.float32),
                            torch.arange(w, device=dev, dtype=torch.float32), indexing="ij")
    return gx.expand(n, h, w), gy.expand(n, h, w)


# Backward warp by a flow in pixels, as the GPU path samples: bilinear, clamped at the border
def warp(img, flow):
    n, _, h, w = img.shape
    gx, gy = grid(n, h, w)
    x = (gx + flow[:, 0]) * (2.0 / (w - 1)) - 1
    y = (gy + flow[:, 1]) * (2.0 / (h - 1)) - 1
    return F.grid_sample(img, torch.stack((x, y), -1), mode="bilinear", padding_mode="border", align_corners=True)


def blend(a, b, flow, mask):
    return warp(a, flow[:, :2]) * mask + warp(b, flow[:, 2:4]) * (1 - mask)


def teacher_net():
    def load(name, path):
        spec = importlib.util.spec_from_file_location(name, path)
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
        return module
    sys.modules["model"] = types.ModuleType("model")
    load("model.warplayer", f"{RIFE_REPO}/model/warplayer.py")
    ifnet = load("ifnet", f"{RIFE_LOG}/IFNet_HDv3.py")
    del sys.modules["model"]
    net = ifnet.IFNet()
    state = torch.load(f"{RIFE_LOG}/flownet.pkl", map_location="cpu", weights_only=True)
    net.load_state_dict({k.replace("module.", ""): v for k, v in state.items() if "module." in k}, strict=False)
    return net.eval().to(dev)


@torch.no_grad()
def teach(net, a, b):
    flows, mask, _ = net(torch.cat((a, b), 1), 0.5, [32, 16, 8, 4, 1])
    return flows[-1].float(), torch.sigmoid(mask.float())


# Overlays: our logo, text in Aileron (CC0, Pillow's default font) and flat panels
def overlay_bank():
    logo = torch.from_numpy(np.asarray(Image.open(f"{DATA}/logo.png").convert("RGBA"))).float() / 255
    bank = [logo]
    words = ["HP", "AMMO", "SCORE", "x", "LV", "FPS", "MAP", "QUEST", "GOLD", "TIME", "Press E", "1/30", "PAUSE"]
    for i in range(96):
        size = random.choice([10, 12, 14, 16, 20, 24, 32, 40])
        text = f"{random.choice(words)} {random.randint(0, 99999)}" if random.random() < 0.7 else \
            "".join(random.choice("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 :/") for _ in range(random.randint(3, 14)))
        font = ImageFont.load_default(size)
        box = font.getbbox(text)
        img = Image.new("RGBA", (box[2] + 8, box[3] + 8), (0, 0, 0, 0))
        draw = ImageDraw.Draw(img)
        color = tuple(random.randint(150, 255) for _ in range(3)) if random.random() < 0.7 else \
            tuple(random.randint(0, 255) for _ in range(3))
        if random.random() < 0.4:
            draw.rectangle([0, 0, img.size[0] - 1, img.size[1] - 1], fill=(0, 0, 0, random.randint(90, 200)))
        draw.text((4, 4), text, font=font, fill=color + (255,), stroke_width=random.choice([0, 0, 1]),
                  stroke_fill=(0, 0, 0, 255))
        bank.append(torch.from_numpy(np.asarray(img)).float() / 255)
    return bank


def paste(frames, rgba, x, y):
    h, w = min(rgba.shape[0], H - y), min(rgba.shape[1], W - x)
    if h <= 0 or w <= 0:
        return
    patch = rgba[:h, :w].permute(2, 0, 1).to(dev)
    alpha = patch[3:4]
    for f in frames:
        f[:, y:y + h, x:x + w] = f[:, y:y + h, x:x + w] * (1 - alpha) + patch[:3] * alpha


# A still HUD on all three frames, as games draw it
def hud(trip, bank):
    for k in range(random.randint(1, 4)):
        item = random.choice(bank)
        if item is bank[0]:
            side = random.choice([32, 48, 64, 96])
            item = F.interpolate(item.permute(2, 0, 1)[None], size=(side, side), mode="bilinear",
                                 align_corners=False)[0].permute(1, 2, 0)
        if random.random() < 0.2:
            w, h = random.randint(40, 200), random.randint(8, 40)
            item = torch.cat((torch.rand(3).expand(h, w, 3), torch.full((h, w, 1), random.uniform(0.4, 1))), -1)
        x = random.choice([random.randint(0, 40), random.randint(0, max(0, W - item.shape[1]))])
        y = random.choice([random.randint(0, 30), random.randint(max(0, H - item.shape[0] - 30), max(0, H - item.shape[0]))])
        paste(trip, item, x, y)


# Layers moving with their own translation, rotation and scale over a moving background, rendered at
# s = -1, 0, 1: disocclusion and rotation with an exact middle frame
def sprites(source, bank):
    n = source.shape[0]
    out = torch.empty(n, 3, 3, H, W, device=dev)
    gx, gy = grid(1, H, W)
    for i in range(n):
        layers = [(source[i], None)]
        for _ in range(random.randint(2, 6)):
            tex = source[random.randrange(n)]
            if random.random() < 0.25:
                t = random.choice(bank[1:])
                layers.append((t.permute(2, 0, 1)[:3].to(dev), t.permute(2, 0, 1)[3:].to(dev)))
            else:
                layers.append((tex, None))
        frames = []
        motions = []
        for li, (tex, alpha) in enumerate(layers):
            th, tw = tex.shape[1:]
            big = li == 0
            reach = random.choice([4, 12, 24, 40, 64]) if not big else random.choice([0, 4, 12, 24, 40])
            motions.append(dict(
                pos=(random.uniform(0, W), random.uniform(0, H)) if not big else (W / 2, H / 2),
                vel=(random.uniform(-reach, reach), random.uniform(-reach, reach) * 0.6),
                rot=random.uniform(-3.14, 3.14) if not big else 0.0,
                spin=random.uniform(-0.25, 0.25) if not big else random.uniform(-0.03, 0.03),
                size=random.uniform(0.15, 0.5) if not big else 1.08,
                grow=random.uniform(-0.08, 0.08) if not big else random.uniform(-0.03, 0.03),
                shape=random.choice(["rect", "ellipse", "round"]),
                aspect=random.uniform(0.4, 2.5)))
        for s in (-1.0, 0.0, 1.0):
            canvas = torch.zeros(3, H, W, device=dev)
            for (tex, alpha), m in zip(layers, motions):
                th, tw = tex.shape[1:]
                px, py = m["pos"][0] + s * m["vel"][0], m["pos"][1] + s * m["vel"][1]
                a = m["rot"] + s * m["spin"]
                k = m["size"] * (1 + s * m["grow"])
                dx, dy = gx[0] - px, gy[0] - py
                c, sn = math.cos(-a), math.sin(-a)
                if alpha is None and m is not motions[0]:
                    sw, sh = W * k * math.sqrt(m["aspect"]), W * k / math.sqrt(m["aspect"]) * 0.5
                else:
                    sw, sh = (tw * k * 4, th * k * 4) if alpha is not None else (W * k, H * k)
                u = (c * dx - sn * dy) / (sw / 2)
                v = (sn * dx + c * dy) / (sh / 2)
                g = torch.stack((u, v), -1)[None]
                col = F.grid_sample(tex[None], g, mode="bilinear", padding_mode="reflection", align_corners=False)[0]
                if m is motions[0]:
                    canvas = col
                    continue
                if alpha is not None:
                    al = F.grid_sample(alpha[None], g, mode="bilinear", padding_mode="zeros", align_corners=False)[0]
                elif m["shape"] == "rect":
                    al = ((u.abs() < 1) & (v.abs() < 1)).float()[None]
                elif m["shape"] == "ellipse":
                    al = (u * u + v * v < 1).float()[None]
                else:
                    al = ((u.abs() ** 4 + v.abs() ** 4) < 1).float()[None]
                canvas = canvas * (1 - al) + col * al
            frames.append(canvas)
        out[i] = torch.stack(frames)
    return out


# fg2/triplets.py's shards: <n>_<split>_b<base>_t<t>_g<gt>_h<hud>.webp, frames stacked vertically
class Shards:
    def __init__(self, root):
        self.items, self.val, self.zips = [], [], {}
        for d, _, files in sorted(os.walk(root)):
            for f in sorted(files):
                if not f.endswith(".zip"):
                    continue
                path = os.path.join(d, f)
                for name in zipfile.ZipFile(path).namelist():
                    parts = name[:-5].split("_")
                    if parts[3] != "t0.5":
                        continue
                    (self.val if parts[1] == "val" and parts[4] == "g1" else self.items).append((path, name, parts[4] == "g1"))
        random.Random(6).shuffle(self.val)
        self.val = self.val[:300]
        say("fg2 samples", len(self.items), "val", len(self.val), "without a true middle",
            sum(1 for i in self.items if not i[2]))

    def load(self, item):
        path, name, gt = item
        z = self.zips.get(path) or self.zips.setdefault(path, zipfile.ZipFile(path))
        img = np.asarray(Image.open(io.BytesIO(z.read(name))).convert("RGB"))
        s = img.shape[1]
        frames = img.reshape(-1, s, s, 3)
        if not gt:
            frames = np.stack((frames[0], np.zeros_like(frames[0]), frames[1]))
        return frames, gt

    def fetch(self, n, items=None):
        picked = [self.load(i) for i in (items or random.sample(self.items, n))]
        x = torch.from_numpy(np.stack([p[0] for p in picked])).to(dev).permute(0, 1, 4, 2, 3).float() / 255
        return x, torch.tensor([float(p[1]) for p in picked], device=dev)


class Data:
    def __init__(self):
        self.sets = [np.load(f"{DATA}/data3d.npy", mmap_mode="r"), np.load(f"{DATA}/databbb.npy", mmap_mode="r")]
        # The last 100 of each set are kept for validation
        self.val = [s[-100:] for s in self.sets]
        self.sets = [s[:-100] for s in self.sets]
        self.bank = overlay_bank()
        self.fg2 = Shards(FG2) if FG2 else None
        if self.fg2 and len(self.fg2.items) < BATCH * 2:
            self.fg2 = None

    def fetch(self, which, n):
        s = self.sets[which]
        idx = sorted(random.sample(range(len(s)), n))
        x = torch.from_numpy(np.stack([s[i] for i in idx])).to(dev)
        return x.permute(0, 1, 4, 2, 3).float() / 255  # N, 3 frames, C, H, W

    # New samples are 256x256: twice as many make the same pixels as a 512x256 batch
    def batch_fg2(self):
        x, gt = self.fg2.fetch(BATCH * 2)
        if random.random() < 0.5:
            x = x.flip(-1)
        if random.random() < 0.2:
            x = x.flip(-2)
        if random.random() < 0.5:
            x = x.flip(1)
        if random.random() < 0.3:
            x = x[:, :, torch.randperm(3)]
        if random.random() < 0.3:
            x = x.clamp(0, 1) ** random.uniform(0.7, 1.4)
        return x[:, 0], x[:, 1], x[:, 2], gt

    def batch(self):
        if self.fg2 is not None and random.random() < 0.55:
            return self.batch_fg2()
        r = random.random()
        if r < 0.4:
            x = self.fetch(0, BATCH)
        elif r < 0.7:
            x = self.fetch(1, BATCH)
        else:
            mixed = torch.cat((self.fetch(0, BATCH // 2), self.fetch(1, BATCH // 2)))
            x = sprites(mixed[:, random.randrange(3)], self.bank)
        if random.random() < 0.3:
            # Zoom into a part, which also makes the motion bigger
            z = random.uniform(1.1, 1.7)
            h, w = int(H / z), int(W / z)
            y0, x0 = random.randint(0, H - h), random.randint(0, W - w)
            x = F.interpolate(x[:, :, :, y0:y0 + h, x0:x0 + w].reshape(-1, 3, h, w), size=(H, W), mode="bilinear",
                              align_corners=False).reshape(BATCH, 3, 3, H, W)
        if random.random() < 0.5:
            x = x.flip(-1)
        if random.random() < 0.2:
            x = x.flip(-2)
        if random.random() < 0.5:
            x = x.flip(1)
        if random.random() < 0.3:
            x = x[:, :, torch.randperm(3)]
        if random.random() < 0.3:
            x = x.clamp(0, 1) ** random.uniform(0.6, 1.5)
        for i in range(BATCH):
            if random.random() < 0.35:
                hud(x[i], self.bank)
        x = x.clamp(0, 1)
        return x[:, 0], x[:, 1], x[:, 2], torch.ones(BATCH, device=dev)


def laplacian(x, levels=4):
    out = []
    for _ in range(levels):
        down = F.avg_pool2d(x, 2)
        out.append(x - F.interpolate(down, scale_factor=2, mode="bilinear", align_corners=False))
        x = down
    out.append(x)
    return out


def charb(x):
    return torch.sqrt(x * x + 1e-6)


def coarse_wrong(out, truth):
    # tune's 2x2 measure: share of 2x2 blocks off by more than 24 levels
    d = (F.avg_pool2d(out, 2) - F.avg_pool2d(truth, 2)).abs().amax(1) * 255
    return (d > 24).float().mean().item() * 100


@torch.no_grad()
def validate(net, teacher, data):
    if net is not None:
        net.eval()
    scores = []
    for which in (0, 1):
        v = data.val[which]
        l1, wrong = 0.0, 0.0
        for j in range(0, len(v), 10):
            x = torch.from_numpy(np.asarray(v[j:j + 10])).to(dev).permute(0, 1, 4, 2, 3).float() / 255
            a, m, b = x[:, 0], x[:, 1], x[:, 2]
            flow, mask = (net(a, b) if net is not None else teach(teacher, a, b))
            out = blend(a, b, flow, mask)
            l1 += (out - m).abs().mean().item() * len(x)
            wrong += coarse_wrong(out, m) * len(x)
        scores.append((l1 / len(v) * 255, wrong / len(v)))
    if data.fg2 is not None and data.fg2.val:
        l1, wrong = 0.0, 0.0
        for j in range(0, len(data.fg2.val), 20):
            x, _ = data.fg2.fetch(0, data.fg2.val[j:j + 20])
            a, m, b = x[:, 0], x[:, 1], x[:, 2]
            flow, mask = (net(a, b) if net is not None else teach(teacher, a, b))
            out = blend(a, b, flow, mask)
            l1 += (out - m).abs().mean().item() * len(x)
            wrong += coarse_wrong(out, m) * len(x)
        scores.append((l1 / len(data.fg2.val) * 255, wrong / len(data.fg2.val)))
    if net is not None:
        net.train()
    return scores


def main():
    data = Data()
    teacher = teacher_net()
    net = A6Flow(CHANNELS).to(dev)
    if INIT:
        net.load_state_dict(torch.load(INIT, map_location="cpu", weights_only=True)["model"])
    opt = torch.optim.AdamW(net.parameters(), lr=PEAK, weight_decay=1e-4)
    step, spent, best = 0, 0.0, float("inf")
    if os.path.exists(f"{RUN}/last.pt"):
        state = torch.load(f"{RUN}/last.pt", map_location="cpu", weights_only=False)
        net.load_state_dict(state["model"])
        opt.load_state_dict(state["opt"])
        step, spent, best = state["step"], state["spent"], state["best"]
        say("resumed at step", step, "after", round(spent / 3600, 2), "h")
    total = HOURS * 3600
    say("teacher val:", describe(validate(None, teacher, data)))
    if INIT and step == 0:
        v = validate(net, teacher, data)
        best = combined(v)
        say("start val:", describe(v), f"| score {best:.3f}")
    say("params", sum(p.numel() for p in net.parameters()), "channels", CHANNELS)
    start = time.time() - spent
    last_save = tick = time.time()
    sums, count = np.zeros(4), 0
    while True:
        spent = time.time() - start
        if spent > total:
            break
        frac = spent / total
        warm = 100 if INIT else 300
        lr = FLOOR + (PEAK - FLOOR) * 0.5 * (1 + math.cos(math.pi * frac)) if step > warm else PEAK * (step + 1) / warm
        for g in opt.param_groups:
            g["lr"] = lr
        a, m, b, gt = data.batch()
        tflow, tmask = teach(teacher, a, b)
        flow, mask = net(a, b)
        out = blend(a, b, flow, mask)
        with torch.no_grad():
            tout = blend(a, b, tflow, tmask)
            # Without a true middle, RIFE's frame stands in for it and RIFE teaches everywhere
            g = gt.view(-1, 1, 1, 1)
            m = m * g + tout * (1 - g)
            better = ((tout - m).abs().mean(1, keepdim=True) + 1e-3 < (out - m).abs().mean(1, keepdim=True)).float()
            better = better * g + (1 - g)
        weight = 0.25 + 0.75 * g
        rec = (charb(out - m) * weight).mean() + sum((charb(p - q) * weight).mean() for p, q in zip(laplacian(out), laplacian(m)))
        distill = (charb(flow - tflow).mean(1, keepdim=True) * better).mean() * 0.02 + \
                  ((mask - tmask).abs() * better).mean() * 0.2
        loss = rec + distill
        opt.zero_grad(set_to_none=True)
        loss.backward()
        torch.nn.utils.clip_grad_norm_(net.parameters(), 1.0)
        opt.step()
        step += 1
        sums += np.array([loss.item(), rec.item(), distill.item(), better.mean().item()])
        count += 1
        if step % (10 if SMOKE else 100) == 0:
            s = sums / count
            say(f"step {step} t {spent / 3600:.3f}h lr {lr:.2e} loss {s[0]:.4f} rec {s[1]:.4f} distill {s[2]:.4f} "
                f"teacher-better {s[3]:.2f} it/s {count / (time.time() - tick):.2f}")
            sums, count, tick = np.zeros(4), 0, time.time()
        if time.time() - last_save > (60 if SMOKE else 1800):
            last_save = time.time()
            save(net, opt, step, time.time() - start, best, data, teacher)
            best = min(best, globals()["last_val"])
            if SEGMENT:
                say("segment ends at step", step)
                return
    save(net, opt, step, time.time() - start, best, data, teacher)
    say("done", step, "steps")


def describe(v):
    names = ("3d", "bbb", "fg2")
    return " | ".join(f"{names[i]} err {e:.2f} 2x2% {w:.2f}" for i, (e, w) in enumerate(v))


def combined(v):
    return sum(w + 0.5 * e for e, w in v)


def save(net, opt, step, spent, best, data, teacher):
    v = validate(net, teacher, data)
    score = combined(v)
    globals()["last_val"] = score
    say(f"val step {step}: {describe(v)} | score {score:.3f}")
    state = {"model": net.state_dict(), "opt": opt.state_dict(), "step": step, "spent": spent,
             "best": min(best, score), "channels": CHANNELS}
    torch.save(state, f"{RUN}/last.pt.tmp")
    os.replace(f"{RUN}/last.pt.tmp", f"{RUN}/last.pt")
    small = {"model": net.state_dict(), "channels": CHANNELS, "step": step, "score": score}
    torch.save(small, f"{RUN}/step{step:07d}.pt")
    if score < best:
        torch.save(small, f"{RUN}/best.pt")
        say("new best", f"{score:.3f}")


last_val = float("inf")
if __name__ == "__main__":
    main()
