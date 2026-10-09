"""Spec screen -> sketch elements placed on a phone frame, plus the gold spec of what was drawn.

The layout is our own (randomised sizes, gaps, alignment), not the source app's pixels, so every sketch
is exactly consistent with its gold spec: whatever had to change to fit the frame (a shortened label, a
dropped trailing element, a list drawn as two repeats instead of "xN") is changed in the gold spec too.
"""

from __future__ import annotations

import copy
from dataclasses import dataclass, field
from typing import Any

import numpy as np

from s2a.data.hershey import text_width
from s2a.spec.naming import DEFAULT_NAV_LABELS

Node = dict[str, Any]
Box = tuple[float, float, float, float]  # x, y, w, h


@dataclass
class Item:
    """One element to draw, in the elements.v1 vocabulary."""

    etype: str
    box: Box
    label: str | None = None
    lines: int = 0  # paragraph lines
    style: dict[str, Any] = field(default_factory=dict)  # drawing variant, e.g. underline input
    go: str | None = None
    node: Node | None = None  # gold node this item realises (for arrows and checks)


@dataclass
class Style:
    """Per-sample layout style, sampled once so a sketch is internally consistent."""

    margin: float
    gap: float
    th: float  # cap height of handwriting, px
    list_mark: float
    underline_input: float
    center_heading: float
    full_btn: float
    nav_labels: bool

    @staticmethod
    def sample(rng: np.random.Generator, cfg: dict[str, Any], w: float, h: float) -> Style:
        def u(key: str) -> float:
            lo, hi = cfg[key]
            return float(rng.uniform(lo, hi))

        return Style(
            margin=u("margin") * w,
            gap=u("gap") * h,
            th=u("text_height") * h,
            list_mark=cfg["list_mark_prob"],
            underline_input=cfg["input_underline_prob"],
            center_heading=cfg["center_heading_prob"],
            full_btn=cfg["btn_full_width_prob"],
            nav_labels=bool(rng.random() < cfg["nav_labels_prob"]),
        )


TEXT_SCALE = {"h1": 1.5, "h2": 1.25, "body": 1.0, "caption": 0.85, "link": 1.0}


def fit_words(text: str, max_w: float, th: float) -> str:
    """Longest word prefix that fits [max_w] when handwritten at cap height [th] (at least one word)."""
    words = text.split()
    out = words[0] if words else text
    for w in words[1:]:
        if text_width(f"{out} {w}", th) > max_w:
            break
        out = f"{out} {w}"
    return out


class ScreenLayout:
    """Lays out one screen. `place()` returns the items and the gold screen actually drawn."""

    def __init__(self, rng: np.random.Generator, cfg: dict[str, Any], frame: Box, scale: float = 1.0) -> None:
        self.rng = rng
        self.frame = frame
        _, _, fw, fh = frame
        self.st = Style.sample(rng, cfg, fw, fh)
        self.scale = scale
        self.th = self.st.th * scale
        self.gap = self.st.gap * scale
        self.items: list[Item] = []

    # ------------------------------------------------------------- measuring

    def _text_h(self, s: str) -> float:
        return self.th * TEXT_SCALE.get(s, 1.0) * 1.9

    def measure(self, n: Node, w: float) -> float:
        t, th = n["t"], self.th
        match t:
            case "text":
                return self._text_h(n.get("s", "body")) + (0.4 * th if n.get("s") in ("h1", "h2") else 0)
            case "para":
                return float(n["lines"]) * th * 1.6
            case "btn":
                return th * 2.8
            case "input":
                return th * 1.8 + th * 2.4
            case "check":
                return th * 2.0
            case "radio":
                return len(n["options"]) * th * 2.0
            case "switch":
                return th * 2.2
            case "img":
                return max(th * 2.5, float(n["h"]) / 100 * self.frame[3] * self.scale)
            case "icon" | "avatar":
                return th * (2.4 if t == "avatar" else 1.8)
            case "divider":
                return th * 0.8
            case "spacer":
                return th * 1.2
            case "card":
                return self._col_h(n["c"], w - 2 * self._pad()) + 2 * self._pad()
            case "col":
                return self._col_h(n["c"], w)
            case "row":
                widths = self._row_widths(n["c"], w)
                return max(self.measure(k, cw) for k, cw in zip(n["c"], widths, strict=True))
            case "list" | "grid":
                return self.measure(n["item"], w) + self.th  # one drawn item (+ its xN mark)
        return th * 2

    def _pad(self) -> float:
        return self.th * 0.8

    def _col_h(self, kids: list[Node], w: float) -> float:
        return sum(self.measure(k, w) for k in kids) + self.gap * 0.7 * max(0, len(kids) - 1)

    def _fixed_w(self, n: Node) -> float | None:
        if n["t"] == "icon":
            return self.th * 1.8
        if n["t"] == "avatar":
            return self.th * 2.4
        return None

    def _row_widths(self, kids: list[Node], w: float) -> list[float]:
        gap = self.th * 0.6
        fixed = [self._fixed_w(k) for k in kids]
        flex = sum(1 for f in fixed if f is None)
        rest = w - sum(f for f in fixed if f is not None) - gap * (len(kids) - 1)
        share = rest / flex if flex else 0
        return [f if f is not None else max(share, self.th * 2) for f in fixed]

    # ------------------------------------------------------------- placing

    def emit(self, etype: str, box: Box, **kw: Any) -> Item:
        item = Item(etype, box, **kw)
        item.style.setdefault("th", self.th)  # the drawer must use the same text size the layout reserved
        self.items.append(item)
        return item

    def place(self, n: Node, x: float, y: float, w: float) -> tuple[Node | None, float]:
        """Place [n] at (x, y) with width w. Returns (gold node as drawn, height used)."""
        t, th = n["t"], self.th
        h = self.measure(n, w)
        match t:
            case "col":
                kids, used = self._place_col(n["c"], x, y, w)
                return ({"t": "col", "c": kids} if kids else None), used
            case "row":
                return self._place_row(n, x, y, w, h)
            case "card":
                pad = self._pad()
                kids, used = self._place_col(n["c"], x + pad, y + pad, w - 2 * pad)
                if not kids:
                    return None, 0.0
                hh = used + 2 * pad
                self.emit("card", (x, y, w, hh), go=n.get("go"), node=n)
                return {**n, "c": kids}, hh
            case "list" | "grid":
                return self._place_repeat(n, x, y, w)
            case "text":
                return self._place_text(n, x, y, w, h)
            case "para":
                lines = []
                for k in range(n["lines"]):
                    lw = w * (
                        self.rng.uniform(0.75, 1.0) if k < n["lines"] - 1 else self.rng.uniform(0.35, 0.8)
                    )
                    lines.append(lw)
                self.emit("para", (x, y, max(lines), h), lines=n["lines"], style={"widths": lines}, node=n)
                return n, h
            case "btn":
                return self._place_btn(n, x, y, w, h)
            case "input":
                label = fit_words(n["label"], w, th)
                style = {"underline": bool(self.rng.random() < self.st.underline_input)}
                self.emit("input", (x, y, w, h), label=label, style=style, node=n)
                return {**n, "label": label}, h
            case "check" | "switch":
                ctl = th * (1.1 if t == "check" else 3.2)
                label = fit_words(n["label"], w - ctl - th, th)
                self.emit("switch" if t == "switch" else "check", (x, y, w, h), label=label, node=n)
                return {**n, "label": label}, h
            case "radio":
                opts = []
                for k, opt in enumerate(n["options"]):
                    label = fit_words(opt, w - 2 * th, th)
                    self.emit("radio", (x, y + k * th * 2.0, w, th * 2.0), label=label, node=n)
                    opts.append(label)
                return {**n, "options": opts}, h
            case "img":
                iw = (
                    w
                    if self.rng.random() < 0.7 or h > 0.25 * self.frame[3]
                    else min(w, h * self.rng.uniform(1.0, 1.6))
                )
                self.emit("img", (x, y, iw, h), node=n)
                return n, h
            case "icon":
                s = th * 1.8
                self.emit(
                    "menu" if n["name"] == "menu" else "icon",
                    (x, y + (h - s) / 2, s, s),
                    go=n.get("go"),
                    node=n,
                )
                return {**n, "name": "menu" if n["name"] == "menu" else "circle"}, h
            case "avatar":
                d = min(w, th * 2.4) if w < 6 * th else th * self.rng.uniform(2.4, 4.0)
                self.emit("avatar", (x, y, d, d), go=n.get("go"), node=n)
                return n, max(h, d)
            case "divider":
                self.emit("divider", (x, y + h / 2, w, 0.0), node=n)
                return n, h
            case "spacer":
                return n, h
        return None, 0.0

    def _place_col(self, kids: list[Node], x: float, y: float, w: float) -> tuple[list[Node], float]:
        out, cy = [], y
        for k in kids:
            gold, used = self.place(k, x, cy, w)
            if gold is not None:
                out.append(gold)
                cy += used + self.gap * 0.7 * self.rng.uniform(0.7, 1.3)
        return out, max(0.0, cy - y - self.gap * 0.7)

    def _place_row(self, n: Node, x: float, y: float, w: float, h: float) -> tuple[Node | None, float]:
        widths = self._row_widths(n["c"], w)
        cx, kids = x, []
        for k, kw in zip(n["c"], widths, strict=True):
            kh = self.measure(k, kw)
            gold, _ = self.place(k, cx, y + (h - kh) / 2, kw)
            if gold is not None:
                kids.append(gold)
            cx += kw + self.th * 0.6
        if not kids:
            return None, 0.0
        return ({"t": "row", "c": kids} if len(kids) > 1 else kids[0]), h

    def _place_text(self, n: Node, x: float, y: float, w: float, h: float) -> tuple[Node, float]:
        s = n.get("s", "body")
        th = self.th * TEXT_SCALE.get(s, 1.0)
        label = fit_words(n["v"], w, th)
        tw = min(w, text_width(label, th))
        heading = s in ("h1", "h2")
        tx = x + (w - tw) / 2 if heading and self.rng.random() < self.st.center_heading else x
        self.emit(
            "heading" if heading else "text",
            (tx, y, tw, h),
            label=label,
            style={"th": th},
            go=n.get("go"),
            node=n,
        )
        return {**n, "v": label}, h

    def _place_btn(self, n: Node, x: float, y: float, w: float, h: float) -> tuple[Node, float]:
        label = fit_words(n["label"], w - 2 * self.th, self.th)
        full = self.rng.random() < self.st.full_btn
        bw = w if full else min(w, text_width(label, self.th) + 2.5 * self.th)
        bx = x if full else x + (w - bw) * self.rng.choice([0.0, 0.5])
        self.emit("btn", (bx, y, bw, h), label=label, go=n.get("go"), node=n)
        return {**n, "label": label}, h

    def _place_repeat(self, n: Node, x: float, y: float, w: float) -> tuple[Node | None, float]:
        """Legend: 'list = one item drawn with xN written beside it, or 2+ repeated items'."""
        item = n["item"]
        mark_w = self.th * 2.6
        if n["t"] == "grid":
            cols = n["cols"]
            cw = (w - mark_w - self.th * 0.6 * (cols - 1)) / cols
            golds, hh = [], 0.0
            for c in range(cols):
                gold, used = self.place(item, x + c * (cw + self.th * 0.6), y, cw)
                if gold is not None:
                    golds.append(gold)
                    hh = max(hh, used)
            if not golds:
                return None, 0.0
            if n["n"] > cols:
                self._mark(n["n"], x + w - mark_w + self.th * 0.4, y + hh / 2)
                return {**n, "item": golds[0]}, hh
            return {**n, "n": cols, "item": golds[0]}, hh
        if self.rng.random() < self.st.list_mark or n["n"] > 3:
            gold, used = self.place(item, x, y, w - mark_w)
            if gold is None:
                return None, 0.0
            self._mark(n["n"], x + w - mark_w + self.th * 0.4, y + used / 2)
            return {**n, "item": gold}, used
        k = int(min(n["n"], self.rng.integers(2, 4)))
        golds, cy = [], y
        for _ in range(k):
            gold, used = self.place(item, x, cy, w)
            if gold is None:
                break
            golds.append(gold)
            cy += used + self.gap * 0.5
        if not golds:
            return None, 0.0
        return {"t": "list", "n": len(golds), "item": golds[0]}, cy - y - self.gap * 0.5

    def _mark(self, count: int, x: float, cy: float) -> None:
        label = f"x{count}"
        self.emit(
            "listmark",
            (x, cy - self.th, text_width(label, self.th * 0.9), self.th * 2),
            label=label,
            style={"th": self.th * 0.9},
        )

    # ------------------------------------------------------------- screen

    def screen(self, screen: Node) -> tuple[list[Item], Node | None]:
        """Lay out a whole screen; returns items and the gold screen (None if nothing fit)."""
        fx, fy, fw, fh = self.frame
        th = self.th
        top, bottom = fy, fy + fh
        gold: Node = {"id": screen["id"], "title": screen["title"]}
        if "appbar" in screen:
            bh = fh * self.rng.uniform(0.06, 0.085)
            ab = screen["appbar"]
            icons = ab.get("icons", [])[:3]
            iw = th * 1.8
            title_w = fw - 2 * self.st.margin - len(icons) * (iw + th)
            title = fit_words(ab["title"], title_w, th * 1.2)
            band = self.emit(
                "appbar",
                (fx, fy, fw, bh),
                label=title,
                style={"line_only": bool(self.rng.random() < 0.5), "th": th * 1.2},
                node=ab,
            )
            gold_icons = []
            for k, ic in enumerate(icons):
                ix = fx + fw - self.st.margin - (k + 1) * (iw + th * 0.6)
                self.emit(
                    "menu" if ic["name"] == "menu" else "icon",
                    (ix, fy + (bh - iw) / 2, iw, iw),
                    go=ic.get("go"),
                    node=ic,
                )
                gold_icons.append({**ic, "name": "menu" if ic["name"] == "menu" else "circle"})
            gold_ab: Node = {"t": "appbar", "title": title}
            if gold_icons:
                gold_ab["icons"] = gold_icons[::-1]  # drawn right-to-left; spec order is left-to-right
            gold["appbar"] = gold_ab
            top = band.box[1] + bh
        if "bottomnav" in screen:
            nh = fh * self.rng.uniform(0.07, 0.095)
            bottom = fy + fh - nh
            self.emit(
                "bottomnav",
                (fx, bottom, fw, nh),
                style={"line_only": bool(self.rng.random() < 0.5)},
                node=screen["bottomnav"],
            )
            items = screen["bottomnav"]["items"]
            slot = fw / len(items)
            gold_items = []
            for k, it in enumerate(items):
                iw = th * 1.6
                ix = fx + slot * (k + 0.5) - iw / 2
                iy = bottom + nh * (0.18 if self.st.nav_labels else 0.3)
                self.emit("icon", (ix, iy, iw, iw), go=it.get("go"), node=it)
                if self.st.nav_labels:
                    label = fit_words(it["label"], slot * 0.9, th * 0.8)
                    lw = text_width(label, th * 0.8)
                    self.emit(
                        "text",
                        (fx + slot * (k + 0.5) - lw / 2, iy + iw + th * 0.2, lw, th * 1.4),
                        label=label,
                        style={"th": th * 0.8},
                    )
                else:
                    label = DEFAULT_NAV_LABELS[k]  # nothing written: the default label is the gold
                gold_items.append(
                    {**{kk: v for kk, v in it.items() if kk != "label"}, "icon": "circle", "label": label}
                )
            gold["bottomnav"] = {"t": "bottomnav", "items": gold_items}
        if "fab" in screen:
            d = th * 3.2
            fab_y = bottom - d - th * 1.5
            self.emit(
                "fab",
                (fx + fw - self.st.margin - d, fab_y, d, d),
                go=screen["fab"].get("go"),
                node=screen["fab"],
            )
            gold["fab"] = {**screen["fab"], "icon": "add"}

        x, w = fx + self.st.margin, fw - 2 * self.st.margin
        y = top + self.gap * 1.2
        avail = bottom - y - th
        body = screen["body"]
        kids = body["c"] if body["t"] == "col" else [body]
        placed, cy = [], y
        for k in kids:
            if cy - y + self.measure(k, w) > avail:
                break  # does not fit: stop here, and the gold spec stops here too
            g, used = self.place(k, x, cy, w)
            if g is not None:
                placed.append(g)
                cy += used + self.gap * self.rng.uniform(0.7, 1.3)
        if not placed:
            return self.items, None
        gold["body"] = (
            placed[0]
            if len(placed) == 1 and placed[0]["t"] in ("list", "grid")
            else {"t": "col", "c": placed}
        )
        return self.items, gold


def layout_screen(
    rng: np.random.Generator, cfg: dict[str, Any], screen: Node, frame: Box
) -> tuple[list[Item], Node | None]:
    """Shrink the layout (down to min_scale) before dropping trailing elements that do not fit."""
    min_scale = cfg["min_scale"]
    best: tuple[list[Item], Node | None] = ([], None)
    best_n = -1
    for scale in (1.0, 0.85, min_scale):
        state = rng.bit_generator.state
        items, gold = ScreenLayout(rng, cfg, frame, scale).screen(copy.deepcopy(screen))
        n = _leaves(gold["body"]) if gold else 0
        if gold and n == _leaves(screen["body"]):
            return items, gold
        if n > best_n:
            best, best_n = (items, gold), n
        rng.bit_generator.state = state  # same style draws at the next scale, only smaller
    return best


def _leaves(n: Node) -> int:
    kids = n.get("c") or ([n["item"]] if "item" in n else [])
    return sum(_leaves(k) for k in kids) if kids else 1
