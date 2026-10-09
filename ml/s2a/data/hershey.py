"""Hershey single-stroke vector fonts -> handwriting-like strokes.

Synthetic text only has to *look like* writing to the stroke recognizer (it decides "this group is
text"); reading the words is ML Kit's job on real ink. Single-stroke fonts give pen paths, not outlines,
which is what ink is. Acknowledgement (required by the font licence): the Hershey Fonts were originally
created by Dr. A. V. Hershey while working at the U. S. National Bureau of Standards; the format of the
font data was originally created by James Hurt, Cognition, Inc.
"""

from __future__ import annotations

from dataclasses import dataclass
from functools import cache
from pathlib import Path

import numpy as np

from s2a.data.download import hershey_dir

FONTS = ("futural", "scripts", "cursive")  # print, simple script, cursive
CAP_HEIGHT = 21.0  # glyph units from cap top (-12) to baseline (+9)
BASELINE = 9.0


@dataclass(frozen=True)
class Glyph:
    left: int
    right: int
    paths: tuple[tuple[tuple[int, int], ...], ...]  # pen-down polylines in glyph units, y down


def parse_jhf(text: str) -> dict[str, Glyph]:
    """Parse a .jhf file; its 96 glyphs are ASCII 32..127 in order."""
    glyphs: dict[str, Glyph] = {}
    lines = [ln for ln in text.splitlines() if ln.strip()]
    for i, line in enumerate(lines):
        n = int(line[5:8])
        body = line[8 : 8 + 2 * n]
        left, right = ord(body[0]) - ord("R"), ord(body[1]) - ord("R")
        paths: list[list[tuple[int, int]]] = [[]]
        for k in range(2, len(body) - 1, 2):
            pair = body[k : k + 2]
            if pair == " R":
                paths.append([])
            else:
                paths[-1].append((ord(pair[0]) - ord("R"), ord(pair[1]) - ord("R")))
        glyphs[chr(32 + i)] = Glyph(left, right, tuple(tuple(p) for p in paths if len(p) >= 1))
    return glyphs


@cache
def load_font(name: str, directory: Path | None = None) -> dict[str, Glyph]:
    path = (directory or hershey_dir()) / f"{name}.jhf"
    return parse_jhf(path.read_text(encoding="ascii"))


def _densify(poly: np.ndarray, step: float) -> np.ndarray:
    """Resample a polyline so consecutive points are ~step apart (touch sensors sample densely)."""
    if len(poly) < 2:
        return poly
    seg = np.linalg.norm(np.diff(poly, axis=0), axis=1)
    total = seg.sum()
    if total <= 0:
        return poly[:1]
    cum = np.concatenate([[0.0], np.cumsum(seg)])
    t = np.linspace(0, total, max(2, int(total / step) + 1))
    return np.stack([np.interp(t, cum, poly[:, 0]), np.interp(t, cum, poly[:, 1])], axis=1)


def text_width(text: str, height: float, font: str = "futural") -> float:
    glyphs = load_font(font)
    scale = height / CAP_HEIGHT
    return sum((glyphs.get(ch, glyphs["?"]).right - glyphs.get(ch, glyphs["?"]).left) * scale for ch in text)


def write_text(
    text: str,
    x: float,
    baseline_y: float,
    height: float,
    rng: np.random.Generator,
    font: str = "futural",
    slant: float = 0.0,
    max_width: float | None = None,
) -> list[np.ndarray]:
    """Strokes (arrays of x, y) for [text] with its baseline at [baseline_y], cap height [height].

    Human-like variation: per-glyph size and position jitter, slant, a wavy baseline, and (for the
    cursive fonts) consecutive pen paths joined into one stroke when they nearly touch.
    """
    glyphs = load_font(font)
    scale = height / CAP_HEIGHT
    if max_width is not None:
        natural = text_width(text, height, font)
        if natural > max_width > 0:
            scale *= max_width / natural  # squeeze rather than run off the element
    strokes: list[np.ndarray] = []
    cursor = x
    wobble_phase = rng.uniform(0, 2 * np.pi)
    for ch in text:
        g = glyphs.get(ch, glyphs["?"])
        gs = scale * rng.uniform(0.9, 1.1)
        dy = rng.normal(0, 0.04 * height) + 0.06 * height * np.sin(
            wobble_phase + cursor / (3 * height + 1e-6)
        )
        for path in g.paths:
            pts = np.array(path, dtype=float)
            px = cursor + (pts[:, 0] - g.left) * gs + slant * (BASELINE - pts[:, 1]) * gs
            py = baseline_y + (pts[:, 1] - BASELINE) * gs + dy
            poly = _densify(np.stack([px, py], axis=1), step=max(0.8, height / 10))
            poly += rng.normal(0, 0.012 * height, poly.shape)
            if font != "futural" and strokes and np.linalg.norm(strokes[-1][-1] - poly[0]) < 0.35 * height:
                strokes[-1] = np.concatenate([strokes[-1], poly])
            else:
                strokes.append(poly)
        cursor += (g.right - g.left) * gs * rng.uniform(0.95, 1.12)
    return [s for s in strokes if len(s) >= 1]
