"""Synthetic photos of paper sketches, and labels for the strokes the app's vectorizer extracts from them.

Photo mode turns a photo into strokes with app/lib/photo/vectorize.dart. Its recognizer must be trained on
those same pseudo-strokes, which have no real drawing order and can merge or split pen lines. So training
photos are rendered here from synthetic samples (every stroke labelled), vectorized by
`dart run tool/batch.dart vectorize` (the exact app code), and each pseudo-stroke takes the label of the
element group under most of its points (`label`). Pseudo-strokes mostly over blank paper are `noise`.

Photo effects (configs/data.yaml `photo`): pen width and darkness, paper brightness, lighting ramp and
vignette, stray marks, a soft shadow, rotation and perspective, a darker table around the sheet, blur,
sensor noise and JPEG compression. Not modelled, so not supported: ruled or squared paper, coloured paper.
"""

from __future__ import annotations

import io
import math
from collections import Counter
from typing import Any

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

from s2a.data.synth import Sample


def homography(src: np.ndarray, dst: np.ndarray) -> np.ndarray:
    """3x3 matrix mapping 4 source points to 4 destination points (direct linear transform)."""
    a, b = [], []
    for (x, y), (u, v) in zip(src, dst, strict=True):
        a.append([x, y, 1, 0, 0, 0, -u * x, -u * y])
        a.append([0, 0, 0, x, y, 1, -v * x, -v * y])
        b += [u, v]
    h = np.linalg.solve(np.asarray(a, float), np.asarray(b, float))
    return np.append(h, 1.0).reshape(3, 3)


def apply(m: np.ndarray, pts: np.ndarray) -> np.ndarray:
    q = np.c_[pts, np.ones(len(pts))] @ m.T
    out: np.ndarray = q[:, :2] / q[:, 2:3]
    return out


def _bbox(pts: np.ndarray) -> list[float]:
    x0, y0 = pts.min(axis=0)
    x1, y1 = pts.max(axis=0)
    return [round(float(x0), 1), round(float(y0), 1), round(float(x1 - x0), 1), round(float(y1 - y0), 1)]


def _smooth_field(rng: np.random.Generator, w: int, h: int, cells: int) -> np.ndarray:
    """Low-frequency noise in [-1, 1] (bicubic upsampling of a small random grid): table grain."""
    small = Image.fromarray((rng.random((cells, cells)) * 255).astype(np.uint8))
    return np.asarray(small.resize((w, h), Image.Resampling.BICUBIC), np.float32) / 127.5 - 1


def render(
    rng: np.random.Generator, sample: Sample, pc: dict[str, Any]
) -> tuple[np.ndarray, np.ndarray, float, dict[str, Any]]:
    """(grey photo HxW uint8, canvas->photo homography, pen width px, effect parameters)."""
    strokes = [np.asarray([p[:2] for p in s["pts"]], float) for s in sample.ink["strokes"]]
    allp = np.concatenate(strokes)
    (x0, y0), (x1, y1) = allp.min(axis=0), allp.max(axis=0)
    margin = float(rng.uniform(*pc["margin"])) * max(x1 - x0, y1 - y0)
    paper = np.array([[x0 - margin, y0 - margin], [x1 + margin, y0 - margin],
                      [x1 + margin, y1 + margin], [x0 - margin, y1 + margin]])  # fmt: skip
    pw, ph = x1 - x0 + 2 * margin, y1 - y0 + 2 * margin
    long_side = int(pc["long_side"])
    w, h = (long_side, long_side * 3 // 4) if pw >= ph else (long_side * 3 // 4, long_side)
    table = bool(rng.random() < pc["table_prob"])
    fill = float(rng.uniform(*pc["paper_fill"])) if table else float(rng.uniform(1.0, 1.08))
    s = fill * min(w / pw, h / ph)
    theta = math.radians(float(rng.uniform(*pc["rotation_deg"])))
    slack = np.array([w, h]) * max(0.0, 1 - fill) / 2
    off = rng.uniform(-slack, slack + 1e-9)
    cx, cy = paper.mean(axis=0)
    c, sn = math.cos(theta), math.sin(theta)
    affine = np.array([[s * c, -s * sn, 0.0], [s * sn, s * c, 0.0], [0.0, 0.0, 1.0]])
    affine[:2, 2] = np.array([w / 2, h / 2]) + off - affine[:2, :2] @ np.array([cx, cy])
    corners = np.array([[0, 0], [w, 0], [w, h], [0, h]], float)
    jitter = rng.uniform(-1, 1, (4, 2)) * pc["perspective"] * np.array([w, h])
    m = homography(corners, corners + jitter) @ affine

    # Paper (or table + sheet), lighting, vignette.
    img = np.full((h, w), float(rng.uniform(*pc["paper_brightness"])), np.float32)
    if table:
        sheet = Image.new("L", (w, h), 0)
        ImageDraw.Draw(sheet).polygon([tuple(p) for p in apply(m, paper)], fill=255)
        tb = float(rng.uniform(*pc["table_brightness"]))
        bg = tb * (1 + 0.15 * _smooth_field(rng, w, h, 6))
        img = np.where(np.asarray(sheet) > 127, img, bg).astype(np.float32)
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    ang = rng.uniform(0, 2 * math.pi)
    proj = (xx * math.cos(ang) + yy * math.sin(ang)).astype(np.float32)
    proj = (proj - proj.min()) / max(float(proj.max() - proj.min()), 1.0)
    img *= 1 - float(rng.uniform(*pc["lighting_ramp"])) * proj
    r2 = ((xx - w / 2) ** 2 + (yy - h / 2) ** 2) / ((w / 2) ** 2 + (h / 2) ** 2)
    img *= 1 - float(rng.uniform(*pc["vignette"])) * r2

    # Ink, drawn at 2x and box-downsampled for anti-aliasing; round dots at stroke ends.
    pen = float(rng.uniform(*pc["pen_width"]))
    ss = 2
    ink = Image.new("L", (w * ss, h * ss), 0)
    draw = ImageDraw.Draw(ink)
    for st in strokes:
        width = max(1.0, pen * (1 + pc["pen_width_jitter"] * float(rng.normal()))) * ss
        q = apply(m, st) * ss
        if len(q) > 1:
            draw.line([tuple(p) for p in q], fill=255, width=max(1, round(width)), joint="curve")
        for p in (q[0], q[-1]):
            draw.ellipse([p[0] - width / 2, p[1] - width / 2, p[0] + width / 2, p[1] + width / 2], fill=255)
    # Stray marks (dots, short scribbles, pen rests) are not in the label map, so their pseudo-strokes
    # are labelled noise: without them the recognizer never learns to ignore anything.
    strays = int(rng.poisson(pc["stray_marks_mean"]))
    for _ in range(strays):
        p0 = apply(m, rng.uniform(paper[0], paper[2])[None])[0]
        steps = int(rng.integers(1, 5))
        walk = p0 + np.cumsum(rng.normal(0, float(rng.uniform(2, 10)), (steps, 2)), axis=0)
        q = np.vstack([p0, walk]) * ss
        width = pen * float(rng.uniform(0.6, 1.3)) * ss
        draw.line([tuple(v) for v in q], fill=255, width=max(1, round(width)), joint="curve")
    alpha = np.asarray(ink.resize((w, h), Image.Resampling.BOX), np.float32) / 255
    ratio = float(rng.uniform(*pc["ink_ratio"]))
    img *= 1 - alpha * (1 - ratio)

    shadow = bool(rng.random() < pc["shadow_prob"])
    if shadow:  # soft-edged shadow of a hand or phone across one side
        a2 = rng.uniform(0, 2 * math.pi)
        d = xx * math.cos(a2) + yy * math.sin(a2)
        edge = float(rng.uniform(np.percentile(d, 55), np.percentile(d, 90)))
        soft = max(w, h) * float(rng.uniform(0.02, 0.08))
        img *= 1 - float(rng.uniform(*pc["shadow_strength"])) / (1 + np.exp(-(d - edge) / soft))

    out = Image.fromarray(np.clip(img, 0, 255).astype(np.uint8))
    blur = float(rng.uniform(*pc["blur_sigma"]))
    if blur > 0.05:
        out = out.filter(ImageFilter.GaussianBlur(blur))
    arr = np.asarray(out, np.float32) + rng.normal(0, float(rng.uniform(*pc["noise_sigma"])), (h, w))
    out = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8))
    quality = None
    if rng.random() < pc["jpeg_prob"]:
        quality = int(rng.integers(pc["jpeg_quality"][0], pc["jpeg_quality"][1] + 1))
        buf = io.BytesIO()
        out.save(buf, "JPEG", quality=quality)
        out = Image.open(io.BytesIO(buf.getvalue())).convert("L")
    params = {"table": table, "pen_width": round(pen, 2), "ink_ratio": round(ratio, 3), "shadow": shadow,
              "blur": round(blur, 2), "jpeg_quality": quality, "stray_marks": strays}  # fmt: skip
    return np.asarray(out, np.uint8), m, pen, params


def label_map(sample: Sample, m: np.ndarray, pen: float, size: tuple[int, int]) -> np.ndarray:
    """Original stroke index + 1 per photo pixel (0 = no ink). Strokes are drawn 2 px wider than the pen so
    skeleton points (on the ink's centre line) land inside their stroke, and largest first so that where a
    small mark touches a big one (an icon on a bar, a label in a box) the small mark keeps its pixels: on
    300 val photos this cut elements left without strokes from 4.9% to 4.5% (icons 10.1% -> 8.2%)."""
    lab = Image.new("I", size, 0)
    draw = ImageDraw.Draw(lab)
    width = max(3, round(pen + 2))
    pts = [apply(m, np.asarray([p[:2] for p in s["pts"]], float)) for s in sample.ink["strokes"]]
    extent = [float(np.ptp(q[:, 0]) + np.ptp(q[:, 1])) for q in pts]
    for k in sorted(range(len(pts)), key=lambda k: -extent[k]):
        q = pts[k]
        if len(q) > 1:
            draw.line([tuple(p) for p in q], fill=k + 1, width=width, joint="curve")
        for p in (q[0], q[-1]):
            draw.ellipse([p[0] - width / 2, p[1] - width / 2, p[0] + width / 2, p[1] + width / 2], fill=k + 1)
    return np.asarray(lab, np.int32)


def label(sample: Sample, m: np.ndarray, pseudo: dict[str, Any], labels: np.ndarray) -> dict[str, Any] | None:
    """Training record for the vectorizer's output: per-pseudo-stroke group from the majority element
    group under its points (class: majority within that group), gold elements/frames/arrows mapped into
    photo coordinates.

    Element boxes come from the original strokes (not the pseudo-strokes), so ink the vectorizer lost
    still counts against recall in evaluation."""
    strokes = pseudo["strokes"]
    if not strokes:
        return None
    h, w = labels.shape
    stroke_cls: list[str] = []
    stroke_group: list[int] = []
    groups = [dict(g) for g in sample.groups]
    for s in strokes:
        pts = np.asarray([p[:2] for p in s["pts"]], float)
        xs = np.clip(np.round(pts[:, 0]).astype(int), 0, w - 1)
        ys = np.clip(np.round(pts[:, 1]).astype(int), 0, h - 1)
        hits = [int(v) - 1 for v in labels[ys, xs] if v > 0]
        if len(hits) < 0.5 * len(pts):  # mostly over blank paper: shadow edge, speck, paper texture
            stroke_cls.append("shape")
            stroke_group.append(len(groups))
            groups.append({"kind": "noise", "type": None, "frame": None})
            continue
        # Vote by element group, not by original stroke: one pseudo-stroke often merges several pen
        # strokes of the same element (a 4-stroke box traced as one loop, a cursive word).
        group = Counter(sample.stroke_group[o] for o in hits).most_common(1)[0][0]
        cls = Counter(sample.stroke_cls[o] for o in hits if sample.stroke_group[o] == group).most_common(1)[
            0
        ][0]
        stroke_cls.append(cls)
        stroke_group.append(group)

    members: dict[int, list[int]] = {}
    for i, g in enumerate(stroke_group):
        members.setdefault(g, []).append(i)
    orig_pts = [np.asarray([p[:2] for p in s["pts"]], float) for s in sample.ink["strokes"]]

    def photo_box(ids: list[int]) -> list[float]:
        return _bbox(apply(m, np.concatenate([orig_pts[i] for i in ids])))

    gold = sample.elements
    frames = []
    for f in gold["frames"]:
        x, y, fw, fh = f["box"]
        frames.append(
            {
                "id": f["id"],
                "box": _bbox(apply(m, np.array([[x, y], [x + fw, y], [x + fw, y + fh], [x, y + fh]]))),
            }
        )
    elements = []
    for el in gold["elements"]:
        g = sample.stroke_group[el["strokes"][0]]
        ids = members.get(g, [])
        out = {
            "id": el["id"],
            "type": el["type"],
            "box": photo_box(el["strokes"]),
            "frame": el["frame"],
            "strokes": ids,
        }
        text = [i for i in ids if stroke_cls[i] == "text"]
        if text:
            out["text_strokes"] = text
        if "text" in el:
            out["text"] = el["text"]
        elements.append(out)
    arrows = []
    for a in gold["arrows"]:
        g = sample.stroke_group[a["strokes"][0]]
        tail, head = apply(m, np.array([a["tail"], a["head"]], float))
        arrows.append(
            {
                "id": a["id"],
                "strokes": members.get(g, []),
                "tail": [round(float(v), 1) for v in tail],
                "head": [round(float(v), 1) for v in head],
            }
        )
    return {
        "ink": {"v": 1, "strokes": strokes, "frames": []},
        "stroke_cls": stroke_cls,
        "stroke_group": stroke_group,
        "groups": groups,
        "elements": {"v": 1, "frames": frames, "elements": elements, "arrows": arrows},
        "spec": sample.spec,
    }


def write_pgm(path: Any, img: np.ndarray) -> None:
    """Binary 8-bit PGM, read by GrayImage.fromPgm in the app."""
    h, w = img.shape
    with open(path, "wb") as f:
        f.write(f"P5\n{w} {h}\n255\n".encode("ascii"))
        f.write(np.ascontiguousarray(img, np.uint8).tobytes())
