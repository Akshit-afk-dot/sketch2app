"""Render ink to PNG for eyeballing: samples, sample grids and the data report."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from PIL import Image, ImageDraw

CLASS_COLORS = {
    "shape": (25, 25, 30),
    "text": (30, 90, 200),
    "arrow": (210, 40, 60),
    "frame": (130, 130, 130),
}


def render_ink(ink: dict[str, Any], stroke_cls: list[str] | None = None, size: int = 512) -> Image.Image:
    """Fit all strokes and template frames into a square image (white background)."""
    pts = [(p[0], p[1]) for s in ink["strokes"] for p in s["pts"]]
    for f in ink.get("frames", []):
        x, y, w, h = f["box"]
        pts += [(x, y), (x + w, y + h)]
    if not pts:
        return Image.new("RGB", (size, size), "white")
    xs, ys = [p[0] for p in pts], [p[1] for p in pts]
    x0, y0, x1, y1 = min(xs), min(ys), max(xs), max(ys)
    scale = (size - 16) / max(x1 - x0, y1 - y0, 1)
    ox, oy = 8 - x0 * scale + ((size - 16) - (x1 - x0) * scale) / 2, 8 - y0 * scale

    def tr(x: float, y: float) -> tuple[float, float]:
        return x * scale + ox, y * scale + oy

    img = Image.new("RGB", (size, size), "white")
    d = ImageDraw.Draw(img)
    for f in ink.get("frames", []):
        x, y, w, h = f["box"]
        d.rounded_rectangle(
            [tr(x, y), tr(x + w, y + h)], radius=int(12 * scale), outline=(200, 200, 210), width=2
        )
    for i, s in enumerate(ink["strokes"]):
        color = CLASS_COLORS.get(stroke_cls[i], (0, 0, 0)) if stroke_cls else (25, 25, 30)
        line = [tr(p[0], p[1]) for p in s["pts"]]
        if len(line) == 1:
            line = line * 2
        d.line(line, fill=color, width=max(1, round(1.6 * scale)), joint="curve")
    return img


def save_grid(images: list[Image.Image], path: Path, cols: int = 4) -> None:
    if not images:
        return
    w, h = images[0].size
    rows = (len(images) + cols - 1) // cols
    grid = Image.new("RGB", (cols * w, rows * h), (240, 240, 244))
    for k, im in enumerate(images):
        grid.paste(im, ((k % cols) * w, (k // cols) * h))
        ImageDraw.Draw(grid).rectangle(
            [(k % cols) * w, (k // cols) * h, (k % cols + 1) * w - 1, (k // cols + 1) * h - 1],
            outline=(200, 200, 205),
        )
    path.parent.mkdir(parents=True, exist_ok=True)
    grid.save(path)
