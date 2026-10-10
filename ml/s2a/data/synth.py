"""Synthetic sketch samples: one or more specs -> ink + per-stroke labels + gold elements + gold spec.

Per-stroke labels are what the recognizer learns from:
    cls    frame | text | shape | arrow    (routing: what the stroke is for)
    group  index into `groups`; strokes with the same group form one element/frame/arrow (grouping head)
The gold element list (elements.v1) and gold spec are the targets for the layout stage.
"""

from __future__ import annotations

import copy
from dataclasses import dataclass, field
from typing import Any

import numpy as np

from s2a.data.augment import augment_screen
from s2a.data.hershey import write_text
from s2a.data.sketch_layout import Item, layout_screen
from s2a.data.strokes import Pen, PenStyle
from s2a.spec import canonicalize, validate
from s2a.spec.naming import screen_names

Node = dict[str, Any]
STROKE_CLASSES = ("frame", "text", "shape", "arrow")


@dataclass
class _Stroke:
    pts: np.ndarray
    cls: str
    group: int


@dataclass
class _Group:
    kind: str  # element | frame | arrow
    etype: str | None = None
    label: str | None = None
    frame: int | None = None
    strokes: list[_Stroke] = field(default_factory=list)
    tail: tuple[float, float] | None = None  # arrows only
    head: tuple[float, float] | None = None


@dataclass
class Sample:
    ink: dict[str, Any]
    stroke_cls: list[str]
    stroke_group: list[int]
    groups: list[dict[str, Any]]
    elements: dict[str, Any]
    spec: dict[str, Any]


# --------------------------------------------------------------------------- naming and links


def _title(screen: Node) -> str | None:
    if "appbar" in screen:
        return str(screen["appbar"]["title"])
    stack = [screen["body"]]
    while stack:
        n = stack.pop(0)
        if n["t"] == "text" and n.get("s") in ("h1", "h2"):
            return str(n["v"])
        stack.extend(n.get("c", []) + ([n["item"]] if "item" in n else []))
    return None


def _rename(screens: list[Node]) -> dict[str, str]:
    """Apply the shared naming rule; returns old id -> new id for rewriting links."""
    names = screen_names([_title(s) for s in screens])
    mapping = {}
    for s, (sid, title) in zip(screens, names, strict=True):
        mapping[s["id"]] = sid
        s["id"], s["title"] = sid, title
    return mapping


def _navigable(screen: Node) -> list[Node]:
    """Nodes that may carry `go`: buttons, cards, icons, avatars, links, FAB, nav items."""
    out: list[Node] = []
    if "appbar" in screen:
        out.extend(screen["appbar"].get("icons", []))
    stack = [screen["body"]]
    while stack:
        n = stack.pop()
        if n["t"] in ("btn", "card", "icon", "avatar") or (n["t"] == "text" and n.get("s") == "link"):
            out.append(n)
        stack.extend(n.get("c", []) + ([n["item"]] if "item" in n else []))
    if "fab" in screen:
        out.append(screen["fab"])
    if "bottomnav" in screen:
        out.extend(screen["bottomnav"]["items"])
    return out


def _add_links(rng: np.random.Generator, screens: list[Node], per_screen: tuple[int, int]) -> None:
    for i, s in enumerate(screens):
        targets = [t["id"] for j, t in enumerate(screens) if j != i]
        cands = [n for n in _navigable(s) if "go" not in n]
        if not cands or not targets:
            continue
        k = min(len(cands), int(rng.integers(per_screen[0], per_screen[1] + 1)))
        for n in rng.choice(len(cands), size=k, replace=False):
            cands[int(n)]["go"] = str(rng.choice(targets))
        if i == 0 and not any(_has_go(n) for n in _navigable(s)):
            cands[0]["go"] = targets[0]


def _has_go(n: Node) -> bool:
    return "go" in n


def _walk_dicts(n: Any) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    stack = [n]
    while stack:
        x = stack.pop()
        if isinstance(x, dict):
            out.append(x)
            stack.extend(x.values())
        elif isinstance(x, list):
            stack.extend(x)
    return out


def _rewrite_go(n: Node, mapping: dict[str, str]) -> None:
    for d in _walk_dicts(n):
        if "go" in d:
            d["go"] = mapping.get(d["go"], d["go"])


def _strip_dead_links(spec: Node) -> None:
    ids = {s["id"] for s in spec["screens"]}
    for d in _walk_dicts(spec):
        if "go" in d and d["go"] not in ids:
            del d["go"]


# --------------------------------------------------------------------------- drawing


class Sketcher:
    def __init__(self, rng: np.random.Generator, cfg: dict[str, Any]) -> None:
        self.rng = rng
        self.cfg = cfg
        self.pen = Pen(rng, PenStyle.sample(rng, cfg["pen"]))
        fonts = cfg["text"]["fonts"]
        self.font = str(rng.choice(list(fonts), p=np.array(list(fonts.values())) / sum(fonts.values())))
        self.slant = float(rng.uniform(*cfg["text"]["slant"]))
        self.groups: list[_Group] = []

    def _text(
        self, label: str, x: float, baseline: float, th: float, max_w: float | None = None
    ) -> list[np.ndarray]:
        return write_text(label, x, baseline, th, self.rng, font=self.font, slant=self.slant, max_width=max_w)

    def draw_item(self, it: Item, frame_id: int) -> _Group:
        g = _Group("element", it.etype, it.label, frame_id)
        x, y, w, h = it.box
        p = self.pen
        shape: list[np.ndarray] = []
        text: list[np.ndarray] = []
        th = float(it.style["th"])  # handwriting size reserved by the layout
        match it.etype:
            case "card":
                shape = p.rect(it.box)
            case "appbar":
                shape = p.line((x, y + h), (x + w, y + h)) if it.style.get("line_only") else p.rect(it.box)
                if it.label:
                    text = self._text(it.label, x + w * 0.06, y + h * 0.5 + th / 2, th, w * 0.6)
            case "bottomnav":
                shape = p.line((x, y), (x + w, y)) if it.style.get("line_only") else p.rect(it.box)
            case "btn":
                shape = p.rect(it.box)
                assert it.label is not None
                text = self._text(it.label, x + th * 1.2, y + h / 2 + th / 2, th, w - th * 2)
            case "input":
                assert it.label is not None
                text = self._text(it.label, x, y + th * 1.3, th, w)
                top = y + th * 1.8
                if it.style.get("underline"):
                    shape = p.line((x, y + h - th * 0.4), (x + w, y + h - th * 0.4))
                else:
                    shape = p.rect((x, top, w, h - th * 1.8))
            case "text" | "heading" | "listmark":
                assert it.label is not None
                text = self._text(it.label, x, y + h * 0.6, th, w * 1.05)
                if it.etype == "heading":
                    uy = y + h * 0.6 + th * 0.45
                    shape = p.line((x, uy), (x + w * float(self.rng.uniform(1.0, 1.15)), uy))
            case "para":
                for k, lw in enumerate(it.style["widths"]):
                    shape += p.wavy(x, y + th * 0.8 + k * th * 1.6, lw, th * 0.35)
            case "img":
                shape = p.rect(it.box) + p.cross((x + w * 0.05, y + h * 0.05, w * 0.9, h * 0.9))
            case "icon":
                shape = p.doodle(it.box)
            case "menu":
                shape = p.menu(it.box)
            case "avatar":
                r = w / 2
                shape = p.ellipse(x + r, y + r, r, r) + p.ellipse(x + r, y + r * 0.8, r * 0.35, r * 0.35)
            case "check" | "radio":
                s = th * 1.1
                cy = y + h / 2
                shape = (
                    p.rect((x, cy - s / 2, s, s))
                    if it.etype == "check"
                    else p.ellipse(x + s / 2, cy, s / 2, s / 2)
                )
                assert it.label is not None
                text = self._text(it.label, x + s + th * 0.6, cy + th / 2, th, w - s - th)
            case "switch":
                pw, ph = th * 3.0, th * 1.4
                px, py = x + w - pw, y + (h - ph) / 2
                pill = (
                    p.ellipse(px + pw / 2, py + ph / 2, pw / 2, ph / 2)
                    if self.rng.random() < 0.5
                    else p.rect((px, py, pw, ph))
                )
                knob_x = px + ph / 2 if self.rng.random() < 0.5 else px + pw - ph / 2
                shape = pill + p.ellipse(knob_x, py + ph / 2, ph * 0.33, ph * 0.33)
                assert it.label is not None
                text = self._text(it.label, x, y + h / 2 + th / 2, th, w - pw - th)
            case "divider":
                shape = p.line((x, y), (x + w, y))
            case "fab":
                r = w / 2
                shape = p.ellipse(x + r, y + r, r, r) + p.plus(x + r, y + r, r * 0.45)
        text_first = self.rng.random() < self.cfg["order"]["text_first_prob"]
        ordered = (
            ([("text", t) for t in text] + [("shape", s) for s in shape])
            if text_first
            else ([("shape", s) for s in shape] + [("text", t) for t in text])
        )
        g.strokes = [_Stroke(pts, cls, -1) for cls, pts in ordered if len(pts) >= 1]
        return g


def _affine(rng: np.random.Generator, cfg: dict[str, Any], center: np.ndarray) -> np.ndarray:
    rot = np.deg2rad(rng.uniform(*cfg["rotation_deg"]))
    sc = rng.uniform(*cfg["scale"])
    sh = rng.uniform(*cfg["shear"])
    m = sc * np.array([[np.cos(rot), -np.sin(rot)], [np.sin(rot), np.cos(rot)]]) @ np.array([[1, sh], [0, 1]])
    return np.vstack([np.hstack([m, (center - m @ center)[:, None]]), [0, 0, 1]])


def _apply(m: np.ndarray, pts: np.ndarray) -> np.ndarray:
    out: np.ndarray = pts @ m[:2, :2].T + m[:2, 2]
    return out


def make_sample(
    rng: np.random.Generator, cfg: dict[str, Any], specs: list[Node], pool: list[str] | None = None
) -> Sample | None:
    """Sketch 1-3 screens (one source spec each, first screen of each) side by side.

    With a label [pool], legend-coverage augmentation inserts rare legend elements first.
    """
    screens = [copy.deepcopy(s["screens"][0]) for s in specs]
    if pool is not None and "augment" in cfg:
        screens = [augment_screen(rng, s, cfg["augment"], pool) for s in screens]
    for k, s in enumerate(screens):
        s["id"] = f"tmp{k}"
    _rename(screens)
    if len(screens) > 1:
        lo, hi = cfg["multiscreen"]["links_per_screen"]
        _add_links(rng, screens, (int(lo), int(hi)))

    canvas = cfg["canvas"]
    sk = Sketcher(rng, cfg)
    frames: list[tuple[float, float, float, float]] = []
    x = 0.0
    for _ in screens:
        fw = float(rng.uniform(*canvas["frame_width"]))
        fh = fw * float(rng.uniform(*canvas["frame_aspect"]))
        frames.append((x, 0.0, fw, fh))
        x += fw + float(rng.uniform(*canvas["frame_gap"]))
    drawn_frames = bool(rng.random() < canvas["drawn_frame_prob"])

    gold_screens: list[Node] = []
    groups: list[_Group] = []
    links: list[tuple[int, str]] = []  # (group index of source element, target old id)
    for fi, (screen, frame) in enumerate(zip(screens, frames, strict=True)):
        items, gold = layout_screen(rng, cfg["layout"], screen, frame)
        if gold is None:
            return None
        gold_screens.append(gold)
        center = np.array([frame[0] + frame[2] / 2, frame[1] + frame[3] / 2])
        m = _affine(rng, cfg["transform"], center)
        if drawn_frames:
            fg = _Group("frame", frame=fi, strokes=[_Stroke(s, "frame", -1) for s in sk.pen.rect(frame)])
            for st in fg.strokes:
                st.pts = _apply(m, st.pts)
            groups.append(fg)
        for it in items:
            g = sk.draw_item(it, fi)
            off = rng.normal(0, cfg["transform"]["element_offset"] * frame[2], 2)
            for st in g.strokes:
                st.pts = _apply(m, st.pts + off)
            if g.strokes:
                if it.go is not None:
                    links.append((len(groups), it.go))
                groups.append(g)

    # Final names from the drawn titles; links follow the renamed ids.
    spec: Node = {"v": 1, "screens": gold_screens}
    remap = _rename(gold_screens)
    for s in gold_screens:
        _rewrite_go(s, remap)
    _strip_dead_links(spec)
    spec = canonicalize(spec)
    if validate(spec):
        return None

    id_to_frame = {s["id"]: k for k, s in enumerate(gold_screens)}
    for gi, target in links:
        tf = id_to_frame.get(remap.get(target, target))
        src = groups[gi]
        if tf is None or tf == src.frame:
            continue
        pts = np.concatenate([s.pts for s in src.strokes])
        fx, fy, fw, fh = frames[tf]
        going_right = fx > frames[src.frame or 0][0]
        tail = np.array([pts[:, 0].max() if going_right else pts[:, 0].min(), pts[:, 1].mean()])
        head = np.array(
            [
                fx + (rng.uniform(10, 50) if going_right else fw - rng.uniform(10, 50)),
                fy + fh * rng.uniform(0.15, 0.6),
            ]
        )
        a, b = (float(tail[0]), float(tail[1])), (float(head[0]), float(head[1]))
        groups.append(
            _Group("arrow", strokes=[_Stroke(s, "arrow", -1) for s in sk.pen.arrow(a, b)], tail=a, head=b)
        )

    return _assemble(rng, cfg, groups, frames, drawn_frames, spec)


def _assemble(
    rng: np.random.Generator,
    cfg: dict[str, Any],
    groups: list[_Group],
    frames: list[tuple[float, float, float, float]],
    drawn_frames: bool,
    spec: Node,
) -> Sample:
    """Order strokes as a person would draw them, add timestamps, and build every label structure."""
    order = list(range(len(groups)))
    if rng.random() < cfg["order"]["shuffled_prob"]:
        rng.shuffle(order)
    else:  # frames first, then elements in reading order, arrows last

        def key(i: int) -> tuple[int, float, float]:
            g = groups[i]
            pts = np.concatenate([s.pts for s in g.strokes])
            rank = {"frame": 0, "element": 1, "arrow": 2}[g.kind]
            return rank, float(pts[:, 0].min() // 400), float(pts[:, 1].min())

        order.sort(key=key)

    timing = cfg["timing"]
    speed = float(rng.uniform(*timing["speed_px_per_s"]))
    t = 0.0
    strokes_json: list[dict[str, Any]] = []
    stroke_cls: list[str] = []
    stroke_group: list[int] = []
    group_strokes: dict[int, list[int]] = {i: [] for i in range(len(groups))}
    group_text: dict[int, list[int]] = {i: [] for i in range(len(groups))}
    for gi in order:
        t += float(rng.uniform(*timing["element_gap_ms"]))
        for s in groups[gi].strokes:
            pts = s.pts
            seg = np.linalg.norm(np.diff(pts, axis=0), axis=1) if len(pts) > 1 else np.zeros(0)
            ts = t + np.concatenate([[0.0], np.cumsum(seg)]) / speed * 1000.0
            sid = len(strokes_json)
            strokes_json.append(
                {
                    "id": sid,
                    "tool": "touch",
                    "pts": [
                        [round(float(px), 1), round(float(py), 1), int(tt)]
                        for (px, py), tt in zip(pts, ts, strict=True)
                    ],
                }
            )
            stroke_cls.append(s.cls)
            stroke_group.append(gi)
            group_strokes[gi].append(sid)
            if s.cls == "text":
                group_text[gi].append(sid)
            t = float(ts[-1]) + float(rng.uniform(*timing["stroke_gap_ms"]))

    def box_of(ids: list[int]) -> list[float]:
        pts = np.asarray([p[:2] for i in ids for p in strokes_json[i]["pts"]], dtype=np.float64)
        x0, y0 = pts.min(axis=0)
        x1, y1 = pts.max(axis=0)
        return [round(float(x0), 1), round(float(y0), 1), round(float(x1 - x0), 1), round(float(y1 - y0), 1)]

    elements: list[dict[str, Any]] = []
    arrows: list[dict[str, Any]] = []
    group_meta: list[dict[str, Any]] = []
    for gi, g in enumerate(groups):
        group_meta.append({"kind": g.kind, "type": g.etype, "frame": g.frame})
        if g.kind == "element":
            el: dict[str, Any] = {
                "id": len(elements),
                "type": g.etype,
                "box": box_of(group_strokes[gi]),
                "frame": g.frame,
                "strokes": sorted(group_strokes[gi]),
            }
            if group_text[gi]:
                el["text_strokes"] = sorted(group_text[gi])
            if g.label:
                el["text"] = g.label
            elements.append(el)
        elif g.kind == "arrow" and g.tail is not None and g.head is not None:
            arrows.append(
                {
                    "id": len(arrows),
                    "strokes": sorted(group_strokes[gi]),
                    "tail": list(g.tail),
                    "head": list(g.head),
                }
            )

    frame_json = [{"id": k, "box": [round(v, 1) for v in f]} for k, f in enumerate(frames)]
    ink = {"v": 1, "strokes": strokes_json, "frames": [] if drawn_frames else frame_json}
    return Sample(
        ink=ink,
        stroke_cls=stroke_cls,
        stroke_group=stroke_group,
        groups=group_meta,
        elements={"v": 1, "frames": frame_json, "elements": elements, "arrows": arrows},
        spec=spec,
    )
