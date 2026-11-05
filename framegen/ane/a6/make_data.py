# Builds the A6 training set: triplets (earlier, true middle, later) at the network's 512x256, as one
# uint8 array of shape (N, 3, 256, 512, 3).
#   3d: the test window's 3D flight (ours) through gen3d, at several sizes, speeds and frame rates.
#       tune scores the flight at 10 to 10.6 s, so those seconds are left out.
#   bbb: Big Buck Bunny 60 fps (CC BY 3.0, Blender Foundation, www.bigbuckbunny.org).
# Usage: make_data.py 3d <gen3d> <out.npy> <count> | make_data.py bbb <movie.mp4> <out.npy> <count>
import os, random, subprocess, sys, tempfile
import numpy as np, torch, torch.nn.functional as F

W, H = 512, 256
kind, tool, out, count = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
rng = random.Random(6)
data = np.lib.format.open_memmap(out, mode="w+", dtype=np.uint8, shape=(count, 3, H, W, 3))


# As the library's ane_input kernel: one bilinear tap at each pixel centre
def shrink(frames):
    x = torch.from_numpy(frames).permute(0, 3, 1, 2).float()
    x = F.interpolate(x, size=(H, W), mode="bilinear", align_corners=False)
    return x.round().clamp(0, 255).byte().permute(0, 2, 3, 1).numpy()


if kind == "3d":
    sizes = [(1280, 300), (1280, 300), (1024, 512), (1280, 720), (960, 544), (768, 384)]
    steps = [1 / 144, 1 / 120, 1 / 90, 1 / 72, 1 / 60, 1 / 48, 1 / 40, 1 / 30, 1 / 24]
    done = 0
    with tempfile.TemporaryDirectory() as tmp:
        while done < count:
            w, h = rng.choice(sizes)
            jobs = []
            for i in range(min(64, count - done)):
                middle = rng.uniform(15, 900)
                speed = rng.choice([0, 4, 8, 16, 16, 24, 32, 48, 64])
                spin = rng.choice([0.25, 0.5, 1, 1, 1.5, 2, 3])
                jobs.append(f"t{i} {middle:.5f} {rng.choice(steps):.6f} {speed} {spin}\n")
            subprocess.run([tool, tmp, str(w), str(h)], input="".join(jobs).encode(), check=True)
            for i in range(len(jobs)):
                path = f"{tmp}/t{i}.raw"
                frames = np.fromfile(path, np.uint8).reshape(3, h, w, 4)[..., 2::-1]
                data[done] = shrink(np.ascontiguousarray(frames))
                os.remove(path)
                done += 1
            print(done, flush=True)
else:
    # Frames i, i + k, i + 2k at 60 fps, away from cuts
    probe = subprocess.run(["ffprobe", "-v", "error", "-count_packets", "-select_streams", "v:0", "-show_entries",
                            "stream=nb_read_packets", "-of", "csv=p=0", tool], capture_output=True, text=True)
    if probe.returncode or not probe.stdout.strip().isdigit():
        sys.exit(f"ffprobe failed on {tool}: {probe.stderr.strip()}")
    total = int(probe.stdout.strip())
    reader = subprocess.Popen(["ffmpeg", "-v", "error", "-i", tool, "-vf", f"scale={W}:{H}:flags=bilinear",
                              "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], stdout=subprocess.PIPE)
    gap = max(1, total // (count + count // 3))
    window, done, index = [], 0, 0
    starts = {}
    while done < count:
        raw = reader.stdout.read(W * H * 3)
        if len(raw) < W * H * 3:
            break
        frame = np.frombuffer(raw, np.uint8).reshape(H, W, 3)
        if index % gap == 0 and index > 600:
            starts[index] = rng.choice([1, 1, 1, 2, 2, 3])
        window.append(frame)
        window = window[-7:]
        for s, k in list(starts.items()):
            if index == s + 2 * k:
                del starts[s]
                a, m, b = window[-1 - 2 * k], window[-1 - k], window[-1]
                diff = lambda x, y: np.abs(x.astype(np.int16) - y).mean()
                if diff(a, m) < 40 and diff(m, b) < 40 and diff(a, b) > 0.5 and abs(diff(a, m) - diff(m, b)) < 15:
                    data[done] = np.stack([a, m, b])
                    done += 1
        index += 1
    reader.kill()
    print("kept", done, "of", count)
    if done < count:
        np.save(out + ".tmp.npy", np.asarray(data[:done]))
        del data
        os.replace(out + ".tmp.npy", out)
data = None
