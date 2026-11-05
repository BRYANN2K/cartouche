# One Nocturne frame (4K EXR holding PQ code values, P3) to a 1280x720 SDR PNG: PQ to nits, a soft
# shoulder around 100 nits, sRGB gamma. Primaries are left as they are.
# Usage: pq_png.py <in.exr> <out.png>
import subprocess, sys, numpy as np
from PIL import Image

W, H = 1280, 720
raw = subprocess.run(["ffmpeg", "-v", "error", "-i", sys.argv[1], "-vf", f"scale={W}:{H}:flags=area", "-f", "rawvideo",
                      "-pix_fmt", "gbrpf32le", "-"], capture_output=True, check=True).stdout
g, b, r = np.frombuffer(raw, np.float32).reshape(3, H, W)
e = np.clip(np.stack((r, g, b), -1), 0, 1) ** (1 / 78.84375)
nits = 10000 * (np.maximum(e - 0.8359375, 0) / (18.8515625 - 18.6875 * e)) ** (1 / 0.1593017578125)
x = nits / 100
sdr = x / (1 + x / 4)
out = np.where(sdr <= 0.0031308, 12.92 * sdr, 1.055 * np.clip(sdr, 0.0031308, 1) ** (1 / 2.4) - 0.055)
Image.fromarray((np.clip(out, 0, 1) * 255 + 0.5).astype(np.uint8)).save(sys.argv[2])
