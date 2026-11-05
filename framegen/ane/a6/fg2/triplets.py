# Turns one high-rate capture into FG 2 training samples, streamed: frames are read once and only
# the samples are kept. A sample is three frames (earlier, true middle, later) or, without a true
# middle, two (RIFE teaches those), as a 256x256 crop of the frame seen at the network's 512x256
# times 1 to 1.6. Base rates come from one capture: at 240 fps, k = 1, 2, 4 gives 120, 60, 30.
# Samples go to zip shards of lossless WebP, named <n>_<split>_b<base fps>_t<t>_g<gt>_h<hud>.webp.
# Usage: triplets.py <dataset dir> <source> raw <width> <height> <time scale> < wincap stream
#        triplets.py <dataset dir> <source> video <file or ffmpeg pattern> <fps> [ffmpeg input args]
# Options (env): FG2_RATES=120,60,30 FG2_MAX=2000 FG2_EVERY=6 FG2_HUD=0.3 FG2_PAIRS=0 FG2_QUARTER=0.1
#                FG2_CAP_GB=9.5 FG2_FLOOR_GB=15 FG2_SEED
import io, os, random, shutil, subprocess, sys, zipfile
import numpy as np
from PIL import Image, ImageDraw, ImageFont

root, source, kind = sys.argv[1], sys.argv[2], sys.argv[3]
env = lambda k, d: type(d)(os.environ.get(k, d))
RATES = [int(r) for r in os.environ.get("FG2_RATES", "120,60,30").split(",")]
MAX, EVERY, HUD = env("FG2_MAX", 2000), env("FG2_EVERY", 6), env("FG2_HUD", 0.3)
PAIRS, QUARTER = env("FG2_PAIRS", 0.0), env("FG2_QUARTER", 0.1)
CAP, FLOOR = env("FG2_CAP_GB", 9.5) * 1e9, env("FG2_FLOOR_GB", 15.0) * 1e9
rng = random.Random(os.environ.get("FG2_SEED", source))
S, NW, NH = 256, 512, 256
here = os.path.dirname(os.path.abspath(__file__))


def du(path):
	return sum(os.path.getsize(os.path.join(d, f)) for d, _, fs in os.walk(path) for f in fs)


used = [0]


def room(full=True):
	if full:
		used[0] = du(root)
	return shutil.disk_usage(root).free > FLOOR and used[0] < CAP


def frames_raw(w, h, scale):
	size = w * h * 4 + 8
	stdin = sys.stdin.buffer
	while True:
		buf = stdin.read(size)
		if len(buf) < size:
			return
		t = np.frombuffer(buf[:8], np.float64)[0] * scale
		yield t, np.frombuffer(buf, np.uint8, offset=8).reshape(h, w, 4)[..., 2::-1]


def frames_video(path, fps, extra):
	probe = subprocess.run(["ffprobe", "-v", "error", *extra, "-i", path, "-select_streams", "v:0", "-show_entries",
	                        "stream=width,height", "-of", "csv=p=0"], capture_output=True, text=True, check=True)
	w, h = (int(x) for x in probe.stdout.split()[0].split(",")[:2])
	scale = min(1.0, 1280 / w)
	w, h = int(w * scale) // 2 * 2, int(h * scale) // 2 * 2
	p = subprocess.Popen(["ffmpeg", "-v", "error", *extra, "-i", path, "-vf", f"scale={w}:{h}:flags=area",
	                      "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], stdout=subprocess.PIPE)
	i = 0
	while True:
		buf = p.stdout.read(w * h * 3)
		if len(buf) < w * h * 3:
			break
		yield i / fps, np.frombuffer(buf, np.uint8).reshape(h, w, 3)
		i += 1
	p.kill()


# HUD drawn the same on every frame, as games do: text in Aileron (CC0, Pillow's default font),
# panels and our logo
WORDS = ["HP", "AMMO", "SCORE", "x", "LV", "FPS", "MAP", "QUEST", "GOLD", "TIME", "Press E", "1/30", "PAUSE", "LAP"]
LOGO = os.path.expanduser("~/Downloads/fg-tests/a6/logo.png")


def hud_layer():
	layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
	draw = ImageDraw.Draw(layer)
	for _ in range(rng.randint(1, 4)):
		x, y = rng.choice([rng.randint(0, 30), rng.randint(0, S - 60)]), rng.choice([rng.randint(0, 20), rng.randint(S - 50, S - 16)])
		r = rng.random()
		if r < 0.15 and os.path.exists(LOGO):
			side = rng.choice([24, 32, 48])
			layer.alpha_composite(Image.open(LOGO).convert("RGBA").resize((side, side)), (min(x, S - side), min(y, S - side)))
		elif r < 0.3:
			w, h = rng.randint(30, 140), rng.randint(6, 30)
			draw.rectangle([x, y, x + w, y + h], fill=tuple(rng.randint(0, 255) for _ in range(3)) + (rng.randint(100, 255),))
		else:
			text = f"{rng.choice(WORDS)} {rng.randint(0, 99999)}"
			font = ImageFont.load_default(rng.choice([9, 10, 12, 14, 16, 20, 24]))
			if rng.random() < 0.4:
				box = draw.textbbox((x, y), text, font=font)
				draw.rectangle([box[0] - 3, box[1] - 3, box[2] + 3, box[3] + 3], fill=(0, 0, 0, rng.randint(90, 200)))
			color = tuple(rng.randint(150, 255) for _ in range(3)) + (255,)
			draw.text((x, y), text, font=font, fill=color, stroke_width=rng.choice([0, 0, 1]), stroke_fill=(0, 0, 0, 255))
	return np.asarray(layer).astype(np.float32) / 255


def view(frames):
	z = rng.uniform(1.0, 1.6)
	w, h = int(NW * z), int(NH * z)
	x0, y0 = rng.randint(0, w - S), rng.randint(0, h - S)
	return [np.asarray(Image.fromarray(f).resize((w, h), Image.BILINEAR, reducing_gap=2.0))[y0:y0 + S, x0:x0 + S] for f in frames]


def d(a, b):
	return np.abs(a.astype(np.int16) - b).mean()


class Shards:
	def __init__(self):
		self.dir = os.path.join(root, source)
		os.makedirs(self.dir, exist_ok=True)
		self.n = len([f for f in os.listdir(self.dir) if f.endswith(".zip")])
		self.zip, self.count, self.total = None, 0, 0

	def add(self, name, img):
		if self.zip is None:
			self.part = os.path.join(self.dir, f"shard{self.n:04d}.zip.part")
			self.zip = zipfile.ZipFile(self.part, "w", zipfile.ZIP_STORED)
		out = io.BytesIO()
		Image.fromarray(img).save(out, "WEBP", lossless=True, method=2)
		self.zip.writestr(f"{self.total:06d}_{name}.webp", out.getvalue())
		self.count += 1
		self.total += 1
		if self.count >= 256:
			self.close()

	def close(self):
		if self.zip is not None:
			self.zip.close()
			os.replace(self.part, self.part[:-5])
			self.zip, self.count, self.n = None, 0, self.n + 1


def main():
	if kind == "raw":
		w, h, scale = int(sys.argv[4]), int(sys.argv[5]), float(sys.argv[6])
		stream, fps = frames_raw(w, h, scale), None
	else:
		fps = float(sys.argv[5])
		stream = frames_video(sys.argv[4], fps, sys.argv[6:])
	shards = Shards()
	window, kept, seen, skipped = [], 0, 0, {}
	for i, (t, frame) in enumerate(stream):
		window.append((t, frame))
		window = window[-17:]
		seen += 1
		if kept >= MAX or i % EVERY or len(window) < 3:
			continue
		if i % 64 == 0 and not room(i % 1024 == 0):
			print(f"{source}: stopped, disk floor or dataset cap reached", flush=True)
			break
		rate = rng.choice(RATES)
		# The capture's real rate, from its time stamps (raw) or as given
		step = (window[-1][0] - window[0][0]) / (len(window) - 1) if fps is None else 1 / fps
		if step <= 0:
			continue
		k = max(1, round(1 / (2 * rate * step)))
		if 2 * k >= len(window):
			continue
		a, m, b = window[-1 - 2 * k], window[-1 - k], window[-1]
		if abs((m[0] - a[0]) - (b[0] - m[0])) > 0.35 * step * k + 1e-4:
			skipped["timing"] = skipped.get("timing", 0) + 1
			continue
		base = round(1 / (2 * k * step))
		base = rate if abs(base - rate) < 0.1 * rate else base
		pair = rng.random() < PAIRS
		quarter = not pair and k % 2 == 0 and rng.random() < QUARTER
		mid = window[-1 - 2 * k + k // 2] if quarter else m
		v = view([a[1], mid[1], b[1]])
		ab, am, mb = d(v[0], v[2]), d(v[0], v[1]), d(v[1], v[2])
		why = "static" if ab < 0.5 and rng.random() > 0.03 else "cut" if am > 40 or mb > 40 else \
			"repeat" if (am < 0.05 or mb < 0.05) and ab > 0.5 else \
			"uneven" if not quarter and abs(am - mb) > 15 else None
		if why:
			skipped[why] = skipped.get(why, 0) + 1
			continue
		hud = rng.random() < HUD
		if hud:
			layer = hud_layer()
			alpha = layer[..., 3:]
			v = [(f * (1 - alpha) + layer[..., :3] * 255 * alpha).round().astype(np.uint8) for f in v]
		split = "val" if (i // 240) % 10 == 9 else "train"
		img = np.concatenate([v[0], v[2]] if pair else v, 0)
		shards.add(f"{split}_b{base}_t{0.25 if quarter else 0.5}_g{0 if pair else 1}_h{int(hud)}", img)
		kept += 1
	shards.close()
	print(f"{source}: {kept} samples from {seen} frames, skipped {skipped}", flush=True)


main()
