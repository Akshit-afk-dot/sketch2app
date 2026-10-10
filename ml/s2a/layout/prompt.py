"""Element list -> compact text prompt for the layout LLM (mirrored in app/lib/layout/prompt.dart).

Example (one screen, then a navigation link):
    S1
    1 img 8,6,84,20
    2 input 8,30,84,6 "Email"
    3 btn 8,52,84,7 "Sign in"
    S2
    4 appbar 0,0,100,8 "Items"
    L 3>S2

Design choices:
- Coordinates are integer percentages of the screen frame (x, w of its width; y, h of its height), so
  the model sees a resolution-independent layout in a few tokens per element.
- Elements are listed per screen in reading order and renumbered 1..N, so ids are short and stable.
- Arrows are resolved geometrically here (tail -> element under it, head -> screen it points into):
  that is deterministic geometry, not something the LLM should have to learn.
Checked against spec/fixtures/prompt/*.json by both languages.
"""

from __future__ import annotations

import math
from typing import Any

INSTRUCTION = "Convert these sketch elements to a Sketch2App UI spec v1 (canonical JSON only)."
MAX_TEXT = 40


def reading_order_frames(frames: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Rows top to bottom, left to right within a row (same rule as the Dart layout builder)."""

    def same_row(a: dict[str, Any], b: dict[str, Any]) -> bool:
        ay, by = a["box"][1] + a["box"][3] / 2, b["box"][1] + b["box"][3] / 2
        return bool(abs(ay - by) < 0.5 * min(a["box"][3], b["box"][3]))

    out = sorted(frames, key=lambda f: (f["box"][1], f["box"][0]))
    # Stable insertion by row, then x.
    rows: list[list[dict[str, Any]]] = []
    for f in out:
        for row in rows:
            if same_row(row[0], f):
                row.append(f)
                break
        else:
            rows.append([f])
    return [f for row in rows for f in sorted(row, key=lambda f: f["box"][0])]


def half_up(v: float) -> int:
    """Round half away from zero for positives (Dart's round()); Python's round() is half-to-even."""
    return math.floor(v + 0.5)


def _center(b: list[float]) -> tuple[float, float]:
    return b[0] + b[2] / 2, b[1] + b[3] / 2


def _contains(b: list[float], x: float, y: float, pad: float = 0.0) -> bool:
    return b[0] - pad <= x <= b[0] + b[2] + pad and b[1] - pad <= y <= b[1] + b[3] + pad


def _frame_of(el: dict[str, Any], frames: list[dict[str, Any]]) -> int:
    """Index (in reading order) of the frame containing the element's centre, else the nearest one."""
    cx, cy = _center(el["box"])
    for k, f in enumerate(frames):
        if _contains(f["box"], cx, cy):
            return k
    return min(range(len(frames)), key=lambda k: _dist_to_box(frames[k]["box"], cx, cy))


def _dist_to_box(b: list[float], x: float, y: float) -> float:
    dx = max(b[0] - x, 0.0, x - (b[0] + b[2]))
    dy = max(b[1] - y, 0.0, y - (b[1] + b[3]))
    return math.hypot(dx, dy)


def clean_text(t: str | None) -> str | None:
    if not t:
        return None
    t = " ".join(t.replace('"', "'").split())[:MAX_TEXT]
    return t or None


def format_elements(el: dict[str, Any]) -> str:
    frames = reading_order_frames(el["frames"])
    if not frames:
        return ""
    per_frame: list[list[dict[str, Any]]] = [[] for _ in frames]
    for e in el["elements"]:
        per_frame[_frame_of(e, frames)].append(e)
    lines: list[str] = []
    number: dict[int, int] = {}
    for k, (f, els) in enumerate(zip(frames, per_frame, strict=True)):
        fx, fy, fw, fh = f["box"]
        lines.append(f"S{k + 1}")
        for e in sorted(els, key=lambda e: (half_up(e["box"][1]), half_up(e["box"][0]), e["id"])):
            number[e["id"]] = len(number) + 1
            x, y, w, h = e["box"]
            q = [
                half_up(100 * (x - fx) / fw),
                half_up(100 * (y - fy) / fh),
                half_up(100 * w / fw),
                half_up(100 * h / fh),
            ]
            text = clean_text(e.get("text"))
            lines.append(
                f"{number[e['id']]} {e['type']} {','.join(str(v) for v in q)}"
                + (f' "{text}"' if text else "")
            )
    for a in el.get("arrows", []):
        src = _arrow_source(a, el["elements"], frames)
        dst = _arrow_target(a, frames)
        if src is not None and dst is not None and src[1] != dst:
            lines.append(f"L {number[src[0]]}>S{dst + 1}")
    return "\n".join(lines)


def _arrow_source(
    a: dict[str, Any], elements: list[dict[str, Any]], frames: list[dict[str, Any]]
) -> tuple[int, int] | None:
    """(element id, frame index) under the arrow's tail: smallest element containing it, else nearest."""
    tx, ty = a["tail"]
    unit = min(f["box"][2] for f in frames)
    inside = [e for e in elements if _contains(e["box"], tx, ty, pad=0.04 * unit)]
    if inside:
        e = min(inside, key=lambda e: e["box"][2] * e["box"][3])
    else:
        near = [(e, _dist_to_box(e["box"], tx, ty)) for e in elements]
        near = [n for n in near if n[1] < 0.15 * unit]
        if not near:
            return None
        e = min(near, key=lambda n: n[1])[0]
    return e["id"], _frame_of(e, frames)


def _arrow_target(a: dict[str, Any], frames: list[dict[str, Any]]) -> int | None:
    hx, hy = a["head"]
    for k, f in enumerate(frames):
        if _contains(f["box"], hx, hy):
            return k
    return min(range(len(frames)), key=lambda k: _dist_to_box(frames[k]["box"], hx, hy)) if frames else None


def build_prompt(el: dict[str, Any]) -> str:
    return f"{INSTRUCTION}\n{format_elements(el)}"
