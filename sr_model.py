"""Real-ESRGAN x2 RRDB architecture, compatible with the published weights.

Architecture adapted from BasicSR (Apache-2.0); see LICENSE-BasicSR.txt.
No BasicSR/torchvision installation is needed.
"""
import torch
from torch import nn
from torch.nn import functional as F


class DenseBlock(nn.Module):
    def __init__(self, features=64, growth=32):
        super().__init__()
        for i in range(1, 6):
            setattr(self, f"conv{i}", nn.Conv2d(
                features + (i - 1) * growth, growth if i < 5 else features, 3, padding=1))

    def forward(self, x):
        values = [x]
        for i in range(1, 5):
            values.append(F.leaky_relu(getattr(self, f"conv{i}")(torch.cat(values, 1)), 0.2))
        return x + self.conv5(torch.cat(values, 1)) * 0.2


class RRDB(nn.Module):
    def __init__(self):
        super().__init__()
        self.rdb1, self.rdb2, self.rdb3 = DenseBlock(), DenseBlock(), DenseBlock()

    def forward(self, x):
        return x + self.rdb3(self.rdb2(self.rdb1(x))) * 0.2


class Upscale2x(nn.Module):
    def __init__(self):
        super().__init__()
        self.conv_first = nn.Conv2d(12, 64, 3, padding=1)
        self.body = nn.Sequential(*(RRDB() for _ in range(23)))
        self.conv_body = nn.Conv2d(64, 64, 3, padding=1)
        self.conv_up1 = nn.Conv2d(64, 64, 3, padding=1)
        self.conv_up2 = nn.Conv2d(64, 64, 3, padding=1)
        self.conv_hr = nn.Conv2d(64, 64, 3, padding=1)
        self.conv_last = nn.Conv2d(64, 3, 3, padding=1)

    def forward(self, x):
        x = self.conv_first(F.pixel_unshuffle(x, 2))
        x = x + self.conv_body(self.body(x))
        x = F.leaky_relu(self.conv_up1(F.interpolate(x, scale_factor=2, mode="nearest")), 0.2)
        x = F.leaky_relu(self.conv_up2(F.interpolate(x, scale_factor=2, mode="nearest")), 0.2)
        return self.conv_last(F.leaky_relu(self.conv_hr(x), 0.2))


def load_model(path):
    state = torch.load(path, map_location="cpu", weights_only=True)
    state = state.get("params_ema", state.get("params", state))
    model = Upscale2x()
    model.load_state_dict(state, strict=True)
    return model.eval().requires_grad_(False)
