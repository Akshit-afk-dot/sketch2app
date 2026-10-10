"""Stroke recognizer: per-stroke encoder -> transformer over strokes -> three heads.

    shape (S, 32, 4) --1D CNN--> 128 ┐
    geom  (S, 16)    --MLP-----> 64  ├─> d_model  + 2D sinusoidal position (stroke centre, size)
                                     ┘            + sinusoidal drawing order
    transformer encoder (pre-norm) over the S strokes of a sketch
    heads: stroke class (frame/text/shape/arrow), element type per stroke (pooled per group later),
           pairwise affinity q_i . k_j -> "same element/frame/arrow" (grouping)

Why a transformer: whether a stroke is a button outline or an image box depends on what is drawn
around it (text inside? an X inside?), i.e. on other strokes; self-attention lets every stroke look at
every other one. Why pairwise affinity: the number of elements is unknown, so grouping is framed as
"do these two strokes belong together?", then clustered.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

import torch
from torch import Tensor, nn

from s2a.recognizer.features import GEOM_DIM, RESAMPLE
from s2a.recognizer.labels import ELEMENT_TYPES, STROKE_CLASSES


@dataclass(frozen=True)
class RecognizerConfig:
    d_model: int = 192
    heads: int = 6
    layers: int = 4
    ffn: int = 768
    dropout: float = 0.1
    affinity_dim: int = 64


def sinusoid(x: Tensor, dim: int, max_period: float = 100.0) -> Tensor:
    """Sinusoidal embedding of a scalar tensor (..., ) -> (..., dim)."""
    half = dim // 2
    freqs = torch.exp(-math.log(max_period) * torch.arange(half, device=x.device, dtype=torch.float32) / half)
    angles = x.float().unsqueeze(-1) * freqs * 2 * math.pi
    out: Tensor = torch.cat([torch.sin(angles), torch.cos(angles)], dim=-1)
    return out


class StrokeEncoder(nn.Module):
    def __init__(self, d_model: int) -> None:
        super().__init__()
        self.conv = nn.Sequential(
            nn.Conv1d(4, 64, 5, padding=2),
            nn.GELU(),
            nn.Conv1d(64, 96, 5, padding=2, stride=2),
            nn.GELU(),
            nn.Conv1d(96, 128, 3, padding=1, stride=2),
            nn.GELU(),
        )
        self.geom = nn.Sequential(nn.Linear(GEOM_DIM, 64), nn.GELU(), nn.Linear(64, 64))
        self.proj = nn.Linear(128 * 2 + 64, d_model)

    def forward(self, shape: Tensor, geom: Tensor) -> Tensor:
        b, s = shape.shape[:2]
        x = shape.reshape(b * s, RESAMPLE, 4).transpose(1, 2)
        h = self.conv(x)
        pooled = torch.cat([h.mean(dim=2), h.amax(dim=2)], dim=1).reshape(b, s, 256)
        out: Tensor = self.proj(torch.cat([pooled, self.geom(geom)], dim=-1))
        return out


class StrokeRecognizer(nn.Module):
    def __init__(self, cfg: RecognizerConfig | None = None) -> None:
        super().__init__()
        self.cfg = cfg = cfg or RecognizerConfig()
        self.encoder = StrokeEncoder(cfg.d_model)
        self.pos = nn.Linear(4 * 32 + 32, cfg.d_model)
        layer = nn.TransformerEncoderLayer(
            cfg.d_model, cfg.heads, cfg.ffn, cfg.dropout, activation="gelu", batch_first=True, norm_first=True
        )
        self.transformer = nn.TransformerEncoder(layer, cfg.layers, enable_nested_tensor=False)
        self.norm = nn.LayerNorm(cfg.d_model)
        self.cls_head = nn.Linear(cfg.d_model, len(STROKE_CLASSES))
        self.type_head = nn.Linear(cfg.d_model, len(ELEMENT_TYPES) + 1)
        self.q = nn.Linear(cfg.d_model, cfg.affinity_dim)
        self.k = nn.Linear(cfg.d_model, cfg.affinity_dim)

    def forward(self, shape: Tensor, geom: Tensor, mask: Tensor) -> tuple[Tensor, Tensor, Tensor]:
        """shape (B,S,32,4), geom (B,S,16), mask (B,S) True for real strokes.

        Returns stroke-class logits (B,S,4), element-type logits (B,S,19) and affinity logits (B,S,S).
        """
        x = self.encoder(shape, geom)
        order = torch.arange(shape.shape[1], device=shape.device).float().expand(shape.shape[0], -1)
        pos = torch.cat(
            [sinusoid(geom[..., i], 32, max_period=8.0) for i in range(4)]  # centre x, y, width, height
            + [sinusoid(order, 32, max_period=512.0)],
            dim=-1,
        )
        x = x + self.pos(pos)
        x = self.norm(self.transformer(x, src_key_padding_mask=~mask))
        q, k = self.q(x), self.k(x)
        affinity = q @ k.transpose(1, 2) / math.sqrt(self.cfg.affinity_dim)
        affinity = (affinity + affinity.transpose(1, 2)) / 2  # "same group" is symmetric
        return self.cls_head(x), self.type_head(x), affinity


def count_parameters(model: nn.Module) -> int:
    return sum(p.numel() for p in model.parameters())
