"""Noisy pen primitives: the visual vocabulary of the sketch legend, drawn like a hurried human would.

Noise sources (all sampled per sample or per primitive, rates in configs/data.yaml):
point jitter and low-frequency wobble, bowed lines, corner overshoot or rounding, outlines drawn in 1, 2
or 4 strokes, closure gaps/overlaps, re-traced sides, broken strokes. The recognizer has to learn to be
robust to exactly what the heuristic baseline is brittle to.
"""

from __future__ import annotations

import itertools
from dataclasses import dataclass

import numpy as np

Stroke = np.ndarray  # (N, 2) float, canvas pixels


@dataclass(frozen=True)
class PenStyle:
    """Per-sample drawing style, so one sketch looks like it came from one person."""

    jitter: float  # gaussian point noise, px
    wobble: float  # low-frequency deviation, fraction of shape size
    overshoot: float  # max corner overshoot, fraction of side length
    rounding: float  # max corner rounding, fraction of the shorter side
    sloppiness: float  # closure gap/overlap, fraction of perimeter
    multi_stroke_rect: float  # probability an outline is drawn in several strokes
    retrace: float  # probability of re-tracing part of an outline
    broken: float  # probability a stroke is lifted and resumed
    step: float  # px between sampled points

    @staticmethod
    def sample(rng: np.random.Generator, cfg: dict[str, list[float]]) -> PenStyle:
        def u(key: str) -> float:
            lo, hi = cfg[key]
            return float(rng.uniform(lo, hi))

        return PenStyle(
            jitter=u("jitter_px"),
            wobble=u("wobble"),
            overshoot=u("overshoot"),
            rounding=u("rounding"),
            sloppiness=u("closure_gap"),
            multi_stroke_rect=u("multi_stroke_rect"),
            retrace=u("retrace"),
            broken=u("broken"),
            step=u("point_step_px"),
        )


def densify(poly: np.ndarray, step: float) -> np.ndarray:
    if len(poly) < 2:
        return poly
    seg = np.linalg.norm(np.diff(poly, axis=0), axis=1)
    total = float(seg.sum())
    if total <= 1e-9:
        return poly[:1]
    cum = np.concatenate([[0.0], np.cumsum(seg)])
    t = np.linspace(0.0, total, max(2, int(total / step) + 1))
    return np.stack([np.interp(t, cum, poly[:, 0]), np.interp(t, cum, poly[:, 1])], axis=1)


class Pen:
    def __init__(self, rng: np.random.Generator, style: PenStyle) -> None:
        self.rng = rng
        self.s = style

    # ------------------------------------------------------------- noise

    def _humanize(self, poly: np.ndarray, size: float) -> np.ndarray:
        """Densify, add a smooth wobble (two random sinusoids along the path) and point jitter."""
        pts = densify(poly, self.s.step)
        n = len(pts)
        if n >= 3:
            t = np.linspace(0, 1, n)
            amp = self.s.wobble * size
            for axis in (0, 1):
                f1, f2 = self.rng.uniform(0.5, 2.0), self.rng.uniform(2.0, 5.0)
                p1, p2 = self.rng.uniform(0, 2 * np.pi, 2)
                pts[:, axis] += amp * (
                    0.7 * np.sin(2 * np.pi * f1 * t + p1) + 0.3 * np.sin(2 * np.pi * f2 * t + p2)
                )
        # Pen noise is correlated between neighbouring samples; white noise would look fuzzy, not hand-drawn.
        noise = self.rng.normal(0, self.s.jitter, pts.shape)
        if n >= 5:
            kernel = np.ones(5) / 5
            noise = np.stack([np.convolve(noise[:, a], kernel, mode="same") for a in (0, 1)], axis=1)
        return pts + noise

    def _maybe_break(self, strokes: list[Stroke]) -> list[Stroke]:
        """Occasionally lift the pen mid-stroke and resume a little further on."""
        out: list[Stroke] = []
        for s in strokes:
            if len(s) > 12 and self.rng.random() < self.s.broken:
                k = int(self.rng.integers(4, len(s) - 4))
                out.extend([s[:k], s[k + 1 :]])
            else:
                out.append(s)
        return out

    # ------------------------------------------------------------- primitives

    def line(self, a: tuple[float, float], b: tuple[float, float]) -> list[Stroke]:
        p0, p1 = np.array(a, float), np.array(b, float)
        length = float(np.linalg.norm(p1 - p0)) + 1e-6
        p0 += self.rng.normal(0, 0.01 * length, 2)
        p1 += self.rng.normal(0, 0.01 * length, 2)
        normal = np.array([-(p1 - p0)[1], (p1 - p0)[0]]) / length
        ctrl = (p0 + p1) / 2 + normal * self.rng.normal(0, 0.02 * length)
        t = np.linspace(0, 1, 16)[:, None]
        bezier = (1 - t) ** 2 * p0 + 2 * (1 - t) * t * ctrl + t**2 * p1
        return self._maybe_break([self._humanize(bezier, length * 0.3)])

    def _corner_path(self, box: tuple[float, float, float, float]) -> np.ndarray:
        """Closed corner sequence with optional rounding, starting at a random corner and direction."""
        x, y, w, h = box
        corners = np.array([[x, y], [x + w, y], [x + w, y + h], [x, y + h]], float)
        start = int(self.rng.integers(0, 4))
        order = np.roll(np.arange(4), -start)
        if self.rng.random() < 0.5:
            order = np.concatenate([[order[0]], order[1:][::-1]])
        r = self.rng.uniform(0, self.s.rounding) * min(w, h)
        pts: list[np.ndarray] = []
        for k in range(4):
            prev_c, c, next_c = corners[order[k - 1]], corners[order[k]], corners[order[(k + 1) % 4]]
            if r > 1:
                d_in = (prev_c - c) / (np.linalg.norm(prev_c - c) + 1e-9)
                d_out = (next_c - c) / (np.linalg.norm(next_c - c) + 1e-9)
                a, b = c + d_in * r, c + d_out * r
                t = np.linspace(0, 1, 5)[:, None]
                pts.extend((1 - t) ** 2 * a + 2 * (1 - t) * t * c + t**2 * b)
            else:
                pts.append(c)
        pts.append(pts[0])
        return np.array(pts)

    def rect(self, box: tuple[float, float, float, float]) -> list[Stroke]:
        size = box[2] + box[3]
        path = self._corner_path(box)
        # Closure noise: stop short of, or run past, the starting point.
        gap = self.rng.uniform(-1, 1) * self.s.sloppiness * 2 * size
        if gap > 0:
            path[-1] = path[-1] + (path[-2] - path[-1]) * min(
                0.9, gap / (np.linalg.norm(path[-2] - path[-1]) + 1e-6)
            )
        else:
            path = np.vstack([path, path[1:2] * 0 + path[0] + (path[1] - path[0]) * min(0.3, -gap / size)])
        if self.rng.random() < self.s.multi_stroke_rect and len(path) >= 5:
            corner_idx = np.linspace(0, len(path) - 1, 5).astype(int)
            split = [0, corner_idx[2], len(path) - 1] if self.rng.random() < 0.6 else list(corner_idx)
            pieces = [path[a : b + 1].copy() for a, b in itertools.pairwise(split)]
            strokes = [self._overshoot(self._humanize(p, size * 0.5), size) for p in pieces if len(p) >= 2]
        else:
            strokes = [self._humanize(path, size * 0.5)]
        if self.rng.random() < self.s.retrace:
            side = strokes[int(self.rng.integers(0, len(strokes)))]
            a = int(self.rng.integers(0, max(1, len(side) // 2)))
            strokes.append(side[a : a + max(3, len(side) // 3)] + self.rng.normal(0, 1.5, (1, 2)))
        return self._maybe_break(strokes)

    def _overshoot(self, s: Stroke, size: float) -> Stroke:
        """Extend a stroke's ends slightly past the corner, as fast pen movements do."""
        if len(s) < 3:
            return s
        ext = self.rng.uniform(0, self.s.overshoot) * min(
            size * 0.5, 120.0
        )  # big frames do not get long tails
        d0 = s[0] - s[1]
        d1 = s[-1] - s[-2]
        d0 /= np.linalg.norm(d0) + 1e-9
        d1 /= np.linalg.norm(d1) + 1e-9
        return np.vstack([s[0] + d0 * ext, s, s[-1] + d1 * ext])

    def ellipse(self, cx: float, cy: float, rx: float, ry: float) -> list[Stroke]:
        start = self.rng.uniform(0, 2 * np.pi)
        sweep = 2 * np.pi * (1 + self.rng.uniform(-1, 1) * self.s.sloppiness * 3)
        direction = 1 if self.rng.random() < 0.6 else -1
        t = start + direction * np.linspace(0, sweep, 40)
        rot = self.rng.normal(0, 0.08)
        ex, ey = rx * np.cos(t), ry * np.sin(t)
        pts = np.stack(
            [cx + ex * np.cos(rot) - ey * np.sin(rot), cy + ex * np.sin(rot) + ey * np.cos(rot)], axis=1
        )
        return self._maybe_break([self._humanize(pts, rx + ry)])

    def wavy(self, x: float, y: float, w: float, amp: float) -> list[Stroke]:
        periods = self.rng.uniform(w / (6 * amp + 1e-6), w / (3 * amp + 1e-6))
        t = np.linspace(0, 1, max(30, int(w / 2)))
        ys = y + amp * np.sin(2 * np.pi * periods * t + self.rng.uniform(0, 2 * np.pi)) * self.rng.uniform(
            0.7, 1.2
        )
        return [self._humanize(np.stack([x + w * t, ys], axis=1), amp * 2)]

    def cross(self, box: tuple[float, float, float, float]) -> list[Stroke]:
        x, y, w, h = box
        if self.rng.random() < 0.15:  # X in one zig-zag stroke
            return [self._humanize(np.array([[x, y], [x + w, y + h], [x + w, y], [x, y + h]], float), w + h)]
        return self.line((x, y), (x + w, y + h)) + self.line((x + w, y), (x, y + h))

    def plus(self, cx: float, cy: float, r: float) -> list[Stroke]:
        return self.line((cx - r, cy), (cx + r, cy)) + self.line((cx, cy - r), (cx, cy + r))

    def arrow(self, a: tuple[float, float], b: tuple[float, float]) -> list[Stroke]:
        """Shaft from a to b plus a head at b: as two short strokes, a 'V', or in one go with the shaft."""
        p0, p1 = np.array(a, float), np.array(b, float)
        length = float(np.linalg.norm(p1 - p0)) + 1e-6
        normal = np.array([-(p1 - p0)[1], (p1 - p0)[0]]) / length
        ctrl = (p0 + p1) / 2 + normal * self.rng.normal(0, 0.15 * length)
        t = np.linspace(0, 1, 30)[:, None]
        shaft = (1 - t) ** 2 * p0 + 2 * (1 - t) * t * ctrl + t**2 * p1
        direction = shaft[-1] - shaft[-4]
        ang = np.arctan2(direction[1], direction[0])
        head_len = self.rng.uniform(10, 18)
        spread = self.rng.uniform(0.35, 0.6)
        wings = [
            p1 - head_len * np.array([np.cos(ang + s * spread), np.sin(ang + s * spread)]) for s in (-1, 1)
        ]
        mode = self.rng.random()
        if mode < 0.2:
            return [self._humanize(np.vstack([shaft, wings[0], p1, wings[1]]), length * 0.1)]
        head = [np.array([wings[0], p1, wings[1]])] if mode < 0.5 else [np.array([p1, w]) for w in wings]
        return [self._humanize(shaft, length * 0.1)] + [self._humanize(hd, head_len) for hd in head]

    def doodle(self, box: tuple[float, float, float, float]) -> list[Stroke]:
        """An icon: a small free-form shape (circle, star, heart-ish loop, square, triangle, squiggle)."""
        x, y, w, h = box
        cx, cy, r = x + w / 2, y + h / 2, min(w, h) / 2
        kind = int(self.rng.integers(0, 6))
        if kind == 0:
            return self.ellipse(cx, cy, r, r)
        if kind == 1:
            ang = np.linspace(-np.pi / 2, 3.5 * np.pi, 11)
            rad = np.where(np.arange(11) % 2 == 0, r, r * 0.45)
            pts = np.stack([cx + rad * np.cos(ang), cy + rad * np.sin(ang)], axis=1)
        elif kind == 2:
            t = np.linspace(0, 2 * np.pi, 40)
            pts = np.stack(
                [cx + r * 0.9 * np.sin(t) ** 3, cy - r * 0.8 * (np.cos(t) - 0.35 * np.cos(2 * t))], axis=1
            )
        elif kind == 3:
            return self.rect((cx - r * 0.8, cy - r * 0.8, r * 1.6, r * 1.6))
        elif kind == 4:
            pts = np.array([[cx, cy - r], [cx + r, cy + r * 0.8], [cx - r, cy + r * 0.8], [cx, cy - r]])
        else:
            t = np.linspace(0, 1, 30)
            pts = np.stack([x + w * t, cy + r * 0.7 * np.sin(6 * np.pi * t) * (1 - abs(2 * t - 1))], axis=1)
        return [self._humanize(pts, r)]

    def menu(self, box: tuple[float, float, float, float]) -> list[Stroke]:
        x, y, w, h = box
        out: list[Stroke] = []
        for k in range(3):
            yy = y + h * (0.2 + 0.3 * k)
            out += self.line((x, yy), (x + w, yy))
        return out
