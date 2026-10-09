"""Stroke features: the recognizer's exact input contract, mirrored in app/lib/recognize/features.dart.

Why strokes rather than a rendered image: ink already arrives segmented into strokes with drawing order
and timing, which are strong cues (an outline is one fast closed stroke; letters are small, many and
close in time). A stroke sequence of ~100 items is also far cheaper than a CNN over a 1-megapixel canvas.

Per stroke:
    shape  (RESAMPLE, 4)  arc-length resampled points relative to the stroke's own box (x, y in [-1, 1]
                          keeping aspect), plus the unit direction (dx, dy) between consecutive points
    geom   (GEOM_DIM,)    position/size in sample units, length, closedness, straightness, timing

Sample units: the ink's bounding-box height / 2. Frames are ~1:2 portrait and laid side by side, so one
unit is about one frame width whatever the canvas zoom, with or without template frames.
Every operation here is simple float math so the Dart port can match it to ~1e-5.
"""

from __future__ import annotations

import math
from typing import Any

import numpy as np

RESAMPLE = 32
GEOM_DIM = 16


def sample_unit(points: list[np.ndarray], frames: list[list[float]]) -> tuple[float, float, float]:
    """(origin_x, origin_y, unit). Template frames, when present, define the scale exactly."""
    if frames:
        x0 = min(f[0] for f in frames)
        y0 = min(f[1] for f in frames)
        unit = float(np.median([f[3] for f in frames])) / 2
        return x0, y0, max(unit, 1e-3)
    allp = np.concatenate(points)
    x0, y0 = float(allp[:, 0].min()), float(allp[:, 1].min())
    unit = float(allp[:, 1].max() - y0) / 2
    return x0, y0, max(unit, 1e-3)


def resample(pts: np.ndarray, n: int = RESAMPLE) -> np.ndarray:
    """n points equally spaced along the polyline (a dot repeats its single point).

    Exact repeated points are dropped first so arc length is strictly increasing; then plain linear
    interpolation (np.interp), which the Dart port reproduces segment by segment.
    """
    keep = np.concatenate([[True], np.any(pts[1:] != pts[:-1], axis=1)])
    pts = pts[keep]
    if len(pts) == 1:
        return np.repeat(pts, n, axis=0)
    seg = np.sqrt(((pts[1:] - pts[:-1]) ** 2).sum(axis=1))
    cum = np.concatenate([[0.0], np.cumsum(seg)])
    targets = np.linspace(0.0, cum[-1], n)
    return np.stack([np.interp(targets, cum, pts[:, 0]), np.interp(targets, cum, pts[:, 1])], axis=1)


def stroke_features(
    pts: np.ndarray,
    times: np.ndarray,
    prev_end_t: float | None,
    origin: tuple[float, float, float],
    t0: float,
) -> tuple[np.ndarray, np.ndarray]:
    ox, oy, unit = origin
    r = resample(pts)
    x0, y0 = r[:, 0].min(), r[:, 1].min()
    x1, y1 = r[:, 0].max(), r[:, 1].max()
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    half = max(x1 - x0, y1 - y0) / 2
    half = half if half > 1e-6 else 1.0
    rel = np.stack([(r[:, 0] - cx) / half, (r[:, 1] - cy) / half], axis=1)
    d = np.diff(r, axis=0)
    norm = np.sqrt((d**2).sum(axis=1, keepdims=True))
    unit_dir = np.where(norm > 1e-9, d / np.maximum(norm, 1e-9), 0.0)
    unit_dir = np.vstack([unit_dir, unit_dir[-1:]])
    shape = np.concatenate([rel, unit_dir], axis=1).astype(np.float32)

    seg = np.sqrt(((pts[1:] - pts[:-1]) ** 2).sum(axis=1)) if len(pts) > 1 else np.zeros(1)
    length = float(seg.sum())
    w, h = float(pts[:, 0].max() - pts[:, 0].min()), float(pts[:, 1].max() - pts[:, 1].min())
    diag = math.sqrt(w * w + h * h)
    gap = float(np.sqrt(((pts[0] - pts[-1]) ** 2).sum()))
    duration = float(times[-1] - times[0])
    pause = 0.0 if prev_end_t is None else float(times[0] - prev_end_t)
    geom = np.array(
        [
            (float(pts[:, 0].min()) + w / 2 - ox) / unit,  # center x
            (float(pts[:, 1].min()) + h / 2 - oy) / unit,  # center y
            w / unit,
            h / unit,
            math.log1p(length / unit * 10),
            gap / diag if diag > 1e-6 else 0.0,  # closedness (0 = closed)
            gap / length if length > 1e-6 else 1.0,  # straightness
            math.log1p(len(pts)) / 6,
            math.log1p(max(duration, 0.0) / 100),
            math.log1p(max(pause, 0.0) / 100),
            (float(times[0]) - t0) / 60000.0,  # minutes since first stroke
            (float(pts[0, 0]) - ox) / unit,
            (float(pts[0, 1]) - oy) / unit,
            (float(pts[-1, 0]) - ox) / unit,
            (float(pts[-1, 1]) - oy) / unit,
            math.log((w + 1e-3) / (h + 1e-3)) / 4,  # aspect
        ],
        dtype=np.float32,
    )
    return shape, geom


def ink_features(ink: dict[str, Any]) -> tuple[np.ndarray, np.ndarray]:
    """(shape [S, RESAMPLE, 4], geom [S, GEOM_DIM]) for an ink.v1 document, strokes in drawing order."""
    strokes = ink["strokes"]
    if not strokes:
        return np.zeros((0, RESAMPLE, 4), np.float32), np.zeros((0, GEOM_DIM), np.float32)
    pts = [np.asarray([[p[0], p[1]] for p in s["pts"]], dtype=np.float64) for s in strokes]
    times = [np.asarray([p[2] for p in s["pts"]], dtype=np.float64) for s in strokes]
    origin = sample_unit(pts, [f["box"] for f in ink.get("frames", [])])
    t0 = float(times[0][0])
    shapes, geoms = [], []
    prev: float | None = None
    for p, t in zip(pts, times, strict=True):
        s, g = stroke_features(p, t, prev, origin, t0)
        shapes.append(s)
        geoms.append(g)
        prev = float(t[-1])
    return np.stack(shapes), np.stack(geoms)
