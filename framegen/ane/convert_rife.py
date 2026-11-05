# Converts Practical-RIFE's IFNet (code and weights MIT, per the project's README) to a Core ML
# program at a fixed size: two RGB frames in, the two flows to t=0.5 and the blend mask out.
# Usage: convert_rife.py <rife train_log dir> <rife repo dir> <width> <height> <out.mlpackage>
import importlib.util, sys, types, torch, coremltools as ct

log, repo, W, H, out = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
# lean: warps at each block's own size, and the last block (full input size) left out
LEAN = len(sys.argv) > 6 and sys.argv[6] == 'lean'

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module

sys.modules["model"] = types.ModuleType("model")
load("model.warplayer", f"{repo}/model/warplayer.py")
ifnet = load("ifnet", f"{log}/IFNet_HDv3.py")

def grid_for(h, w):
    gx = torch.linspace(-1.0, 1.0, w).view(1, 1, 1, w).expand(1, 1, h, w)
    gy = torch.linspace(-1.0, 1.0, h).view(1, 1, h, 1).expand(1, 1, h, w)
    return torch.cat([gx, gy], 1)

grids = {}

def warp(image, flow):
    h, w = image.shape[2], image.shape[3]
    h, w = int(h), int(w)
    if (h, w) not in grids:
        grids[(h, w)] = grid_for(h, w)
    flow = torch.cat([flow[:, 0:1] / ((w - 1.0) / 2.0), flow[:, 1:2] / ((h - 1.0) / 2.0)], 1)
    return torch.nn.functional.grid_sample(image, (grids[(h, w)] + flow).permute(0, 2, 3, 1), mode="bilinear",
                                           padding_mode="border", align_corners=True)

ifnet.warp = warp
net = ifnet.IFNet().eval()
state = torch.load(f"{log}/flownet.pkl", map_location="cpu", weights_only=True)
net.load_state_dict({k.replace("module.", ""): v for k, v in state.items() if "module." in k}, strict=False)

import torch.nn.functional as F

def resize(x, h, w):
    return F.interpolate(x, size=(h, w), mode="bilinear", align_corners=False)

# IFNet's inference pass with every size written out, so the trace has no shape arithmetic
def block_pass(block, x, flow, scale):
    h, w = H // scale, W // scale
    x = resize(x, h, w)
    if flow is not None:
        x = torch.cat((x, resize(flow, h, w) * (1.0 / scale)), 1)
    tmp = resize(block.lastconv(block.convblock(block.conv0(x))), H, W)
    return tmp[:, :4] * scale, tmp[:, 4:5], tmp[:, 5:]

class Flow(torch.nn.Module):
    def __init__(self, net):
        super().__init__()
        self.net = net
    def forward(self, a, b):
        n = self.net
        t = a[:, :1] * 0 + 0.5
        f0, f1 = n.encode(a), n.encode(b)
        blocks = [n.block0, n.block1, n.block2, n.block3, n.block4]
        scales = [32, 16, 8, 4, 1]
        if LEAN:
            blocks, scales = blocks[:4], scales[:4]
        flow, mask, feat = block_pass(blocks[0], torch.cat((a, b, f0, f1, t), 1), None, scales[0])
        for block, scale in zip(blocks[1:], scales[1:]):
            if LEAN:
                # Everything at this block's size: the inputs shrink first, then warp
                h, w = H // scale, W // scale
                small = lambda x: resize(x, h, w)
                fs = small(flow) * (1.0 / scale)
                x = torch.cat((warp(small(a), fs[:, :2]), warp(small(b), fs[:, 2:4]), warp(small(f0), fs[:, :2]),
                               warp(small(f1), fs[:, 2:4]), small(t), small(mask), small(feat), fs), 1)
                tmp = resize(block.lastconv(block.convblock(block.conv0(x))), H, W)
                fd, mask, feat = tmp[:, :4] * scale, tmp[:, 4:5], tmp[:, 5:]
            else:
                wa, wb = warp(a, flow[:, :2]), warp(b, flow[:, 2:4])
                wf0, wf1 = warp(f0, flow[:, :2]), warp(f1, flow[:, 2:4])
                fd, mask, feat = block_pass(block, torch.cat((wa, wb, wf0, wf1, t, mask, feat), 1), flow, scale)
            flow = flow + fd
        return flow, torch.sigmoid(mask)

model = Flow(net).eval()
a, b = torch.rand(1, 3, H, W), torch.rand(1, 3, H, W)
with torch.no_grad():
    traced = torch.jit.trace(model, (a, b), check_trace=False)
ml = ct.convert(traced, inputs=[ct.TensorType("a", a.shape), ct.TensorType("b", b.shape)],
                outputs=[ct.TensorType("flow"), ct.TensorType("mask")],
                compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.macOS15)
ml.save(out)
print("saved", out, sum(p.numel() for p in net.parameters()), "params")
