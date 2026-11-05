# Converts an A6 checkpoint (or random weights, for a placement check) to a Core ML program with
# RIFE lean's names and sizes, so the helper loads it unchanged.
# Usage: convert.py <checkpoint.pt | random> <out.mlpackage> [channels, e.g. 16,32,48,64,96]
import sys, torch, coremltools as ct
from model import A6Flow

W, H = 512, 256
source, out = sys.argv[1], sys.argv[2]
state = None if source == "random" else torch.load(source, map_location="cpu", weights_only=True)
channels = tuple(int(c) for c in sys.argv[3].split(",")) if len(sys.argv) > 3 else (state or {}).get("channels")
net = A6Flow(channels) if channels else A6Flow()
if state is not None:
    net.load_state_dict(state["model"])
net.eval()
a, b = torch.rand(1, 3, H, W), torch.rand(1, 3, H, W)
with torch.no_grad():
    traced = torch.jit.trace(net, (a, b))
ml = ct.convert(traced, inputs=[ct.TensorType("a", a.shape), ct.TensorType("b", b.shape)],
                outputs=[ct.TensorType("flow"), ct.TensorType("mask")],
                compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.macOS15)
ml.save(out)
print("saved", out, sum(p.numel() for p in net.parameters()), "params")
