# The A6 flow network: RIFE lean's interface (two RGB frames in, the flows from the middle frame to
# each of them and the blend mask out) with convolutions only, so all of it runs on the ANE. The
# warps happen on the GPU, and in training only.
import torch
import torch.nn as nn
import torch.nn.functional as F


def conv(i, o, stride=1):
    return nn.Sequential(nn.Conv2d(i, o, 3, stride, 1), nn.LeakyReLU(0.2, True))


class Level(nn.Module):
    # One decoder step: features, the skip from the encoder and the coarser estimate in, a finer
    # estimate (4 flow channels, 1 mask logit) and features out
    def __init__(self, i, c):
        super().__init__()
        self.body = nn.Sequential(conv(i, c), conv(c, c), conv(c, c))
        self.head = nn.Conv2d(c, 5, 3, 1, 1)

    def forward(self, x):
        x = self.body(x)
        return x, self.head(x)


class A6Flow(nn.Module):
    def __init__(self, c=(16, 32, 48, 64, 96)):
        super().__init__()
        self.stem = nn.Sequential(conv(3, c[0], 2), conv(c[0], c[0]), conv(c[0], c[1], 2), conv(c[1], c[1]))
        self.down = nn.ModuleList([
            nn.Sequential(conv(2 * c[1], c[2], 2), conv(c[2], c[2])),
            nn.Sequential(conv(c[2], c[3], 2), conv(c[3], c[3])),
            nn.Sequential(conv(c[3], c[4], 2), conv(c[4], c[4])),
        ])
        self.top = Level(c[4], c[4])
        self.levels = nn.ModuleList([Level(c[4] + c[3] + 5, c[3]), Level(c[3] + c[2] + 5, c[2]),
                                     Level(c[2] + 2 * c[1] + 5, c[1])])
        self.up = nn.ModuleList([nn.ConvTranspose2d(c[4], c[4], 4, 2, 1), nn.ConvTranspose2d(c[3], c[3], 4, 2, 1),
                                 nn.ConvTranspose2d(c[2], c[2], 4, 2, 1)])

    # Flow (in pixels of the input) and mask logit, at 1/4 of the input's size
    def quarter(self, a, b):
        x = torch.cat((self.stem(a), self.stem(b)), 1)
        skips = [x]
        for d in self.down:
            x = d(x)
            skips.append(x)
        feat, est = self.top(skips.pop())
        est = torch.cat((est[:, :4] * 32.0, est[:, 4:]), 1)
        # Each level sees and corrects the flow in its own pixels
        for level, up, scale in zip(self.levels, self.up, (16.0, 8.0, 4.0)):
            coarse = F.interpolate(est, scale_factor=2.0, mode="bilinear", align_corners=False)
            seen = torch.cat((coarse[:, :4] * (1.0 / scale), coarse[:, 4:]), 1)
            feat, delta = level(torch.cat((up(feat), skips.pop(), seen), 1))
            est = coarse + torch.cat((delta[:, :4] * scale, delta[:, 4:]), 1)
        return est

    def forward(self, a, b):
        est = self.quarter(a, b)
        full = F.interpolate(est, scale_factor=4.0, mode="bilinear", align_corners=False)
        return full[:, :4], torch.sigmoid(full[:, 4:5])
