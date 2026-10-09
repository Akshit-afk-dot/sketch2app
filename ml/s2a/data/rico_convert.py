"""RICO semantic hierarchy -> canonical UI spec.

RICO gives real app structure (what appears together, in what order, with what text). We keep the
structure and content, and simplify the presentation to our closed vocabulary. Geometry is used only to
recover rows, repetition and text styles; the synthetic sketcher later re-lays-out every spec itself, so
sketch and spec are always consistent.

    python -m s2a.data.rico_convert            # -> $S2A_DATA_ROOT/rico_specs/specs.jsonl + stats.json
"""

from __future__ import annotations

import csv
import json
import math
import re
import statistics
from collections import Counter
from collections.abc import Iterable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from s2a.data.download import rico_dir
from s2a.paths import data_root
from s2a.spec import canonicalize, validate

Node = dict[str, Any]

# RICO iconClass -> our icon names (unlisted classes become the generic "circle").
ICON_MAP = {
    "arrow_backward": "back", "arrow_forward": "forward", "more": "more", "menu": "menu", "search": "search",
    "play": "play", "close": "close", "star": "star", "add": "add", "favorite": "favorite", "chat": "chat",
    "share": "share", "settings": "settings", "refresh": "refresh", "cart": "cart", "shop": "cart",
    "home": "home", "edit": "edit", "info": "info", "check": "check", "location": "location",
    "location_crosshair": "location", "date_range": "calendar", "photo": "image", "wallpaper": "image",
    "notifications": "bell", "help": "help", "email": "mail", "microphone": "mic", "list": "list",
    "music": "music", "lock": "lock", "call": "phone", "file_download": "download", "delete": "delete",
    "filter_list": "filter", "filter": "filter", "send": "send", "group": "person", "thumbs_up": "favorite",
}  # fmt: skip

MEDIA_AS_IMAGE = {"Advertisement", "Web View", "Map View", "Video"}
DROPPED = {"Background Image", "Pager Indicator", "Slider", "Number Stepper", "Date Picker"}
OVERLAYS = {"Drawer", "Modal"}
MIN_ELEMENTS, MAX_ELEMENTS = 3, 30
MAX_TEXT = 40  # longer strings are paragraphs: nobody hand-writes a sentence on a wireframe


@dataclass
class Comp:
    """One labelled RICO component with its labelled descendants."""

    label: str
    box: tuple[float, float, float, float]  # x1, y1, x2, y2 in screen pixels
    text: str = ""
    icon: str | None = None
    cls: str = ""
    rid: str = ""
    children: list[Comp] = field(default_factory=list)

    @property
    def w(self) -> float:
        return self.box[2] - self.box[0]

    @property
    def h(self) -> float:
        return self.box[3] - self.box[1]

    @property
    def cx(self) -> float:
        return (self.box[0] + self.box[2]) / 2

    @property
    def cy(self) -> float:
        return (self.box[1] + self.box[3]) / 2


def parse_components(node: dict[str, Any]) -> list[Comp]:
    """Labelled components of a RICO hierarchy; unlabelled wrappers are flattened away."""
    kids = [c for child in node.get("children", []) or [] for c in parse_components(child)]
    label = node.get("componentLabel")
    if not label:
        return kids
    b = node.get("bounds") or [0, 0, 0, 0]
    return [
        Comp(
            label=label,
            box=(float(b[0]), float(b[1]), float(b[2]), float(b[3])),
            text=(node.get("text") or "").strip(),
            icon=node.get("iconClass"),
            cls=(node.get("class") or "").rsplit(".", 1)[-1],
            rid=(node.get("resource-id") or "").rsplit("/", 1)[-1],
            children=kids,
        )
    ]


def _walk(comps: Iterable[Comp]) -> Iterable[Comp]:
    for c in comps:
        yield c
        yield from _walk(c.children)


# Basic Latin, Latin-1/Extended-A/B, curly quotes, ellipsis, euro and rupee: what en-US handwriting covers.
_LATIN_RANGES = (
    (0x20, 0x7E),
    (0xA0, 0x24F),
    (0x2018, 0x201D),
    (0x2026, 0x2026),
    (0x20AC, 0x20AC),
    (0x20B9, 0x20B9),
)


def clean_text(s: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"[\x00-\x1f]", " ", s)).strip()


def is_latin(s: str) -> bool:
    return all(any(lo <= ord(ch) <= hi for lo, hi in _LATIN_RANGES) for ch in s)


def label_from_id(rid: str) -> str:
    """'et_new_login_password' -> 'Password': the hint text of inputs is not in RICO, the id often is."""
    words = re.sub(r"([a-z])([A-Z])", r"\1 \2", rid).replace("_", " ").replace("-", " ").lower().split()
    noise = {"et", "edit", "edittext", "txt", "text", "input", "field", "view", "new", "id", "tv", "ed"}
    keep = [w for w in words if w not in noise and not w.isdigit()]
    return " ".join(keep[-2:]).capitalize() if keep else ""


def short(s: str, limit: int = 30) -> str:
    """Trim to whole words within [limit] characters."""
    if len(s) <= limit:
        return s
    out = ""
    for word in s.split():
        if len(out) + len(word) + 1 > limit:
            break
        out = f"{out} {word}".strip()
    return out or s[:limit]


class Converter:
    """Converts one screen. Instances are cheap; one per screen keeps per-screen statistics simple."""

    def __init__(self, width: float, height: float, text_heights: list[float]) -> None:
        self.W, self.H = width, height
        self.median_text_h = statistics.median(text_heights) if text_heights else height * 0.025

    # ---------------------------------------------------------------- leaves

    def text_node(self, c: Comp, link: bool = False) -> Node | None:
        t = clean_text(c.text)
        if not t or not is_latin(t):
            return None
        if len(t) > MAX_TEXT:
            return {"t": "para", "lines": max(1, min(6, math.ceil(len(t) / 45)))}
        if link:
            return {"t": "text", "v": t, "s": "link"}
        r = c.h / self.median_text_h if self.median_text_h > 0 else 1
        style = "h1" if r >= 1.8 else "h2" if r >= 1.35 else "caption" if r <= 0.75 else "body"
        return {"t": "text", "v": t, "s": style}

    def image_node(self, c: Comp, in_item: bool) -> Node:
        w_rel, aspect = c.w / self.W, c.w / max(c.h, 1)
        if w_rel < 0.14 and 0.7 <= aspect <= 1.4:
            return {"t": "avatar"} if in_item else {"t": "icon", "name": "image"}
        return {"t": "img", "h": max(5, min(100, round(100 * c.h / self.H)))}

    def leaf(self, c: Comp, in_item: bool) -> Node | None:
        match c.label:
            case "Text":
                return self.text_node(c)
            case "Text Button":
                if not clean_text(c.text):
                    return self.icon_node(c) if c.icon else None
                if "Button" in c.cls:
                    t = clean_text(c.text)
                    return {"t": "btn", "label": short(t)} if is_latin(t) else None
                return self.text_node(c, link=True)
            case "Input":
                t = clean_text(c.text)
                label = (
                    short(t) if t and is_latin(t) and len(t) <= MAX_TEXT else label_from_id(c.rid) or "Input"
                )
                hint = f"{c.rid} {t}".lower()
                node: Node = {"t": "input", "label": label}
                if "pass" in hint or "pin" in hint:
                    node["secure"] = True
                if c.h > 0.12 * self.H:
                    node["multiline"] = True
                return node
            case "Image":
                return self.image_node(c, in_item)
            case "Icon":
                return self.icon_node(c)
            case "Checkbox":
                t = clean_text(c.text)
                return {"t": "check", "label": short(t) if t and is_latin(t) else "Option"}
            case "On/Off Switch":
                t = clean_text(c.text)
                return {"t": "switch", "label": short(t) if t and is_latin(t) else "Setting"}
            case label if label in MEDIA_AS_IMAGE:
                return {"t": "img", "h": max(5, min(100, round(100 * c.h / self.H)))}
        return None

    def icon_node(self, c: Comp) -> Node:
        if c.icon == "avatar":
            return {"t": "avatar"}
        return {"t": "icon", "name": ICON_MAP.get(c.icon or "", "circle")}

    # ---------------------------------------------------------------- structure

    def node(self, c: Comp, in_item: bool = False) -> Node | None:
        match c.label:
            case "Card" | "List Item":
                kids = self.arrange(c.children, in_item=True)
                if not kids:
                    return None
                if c.label == "Card":
                    return {"t": "card", "c": kids}
                return kids[0] if len(kids) == 1 else {"t": "col", "c": kids}
            case "Button Bar":
                btns = [n for k in c.children if (n := self.node(k, in_item)) is not None]
                return {"t": "row", "c": btns[:4]} if len(btns) >= 2 else (btns[0] if btns else None)
            case "Multi-Tab":
                tabs = [clean_text(k.text) for k in _walk(c.children) if clean_text(k.text)]
                tabs = [short(t, 14) for t in tabs if is_latin(t)][:5]
                if len(tabs) < 2:
                    return None
                return {"t": "row", "c": [{"t": "text", "v": t, "s": "link"} for t in tabs]}
            case "Radio Button":
                t = clean_text(c.text)
                return {"t": "radio", "options": [short(t) if t and is_latin(t) else "Option"]}
            case "Toolbar" | "Bottom Navigation":
                return None  # handled as screen slots; nested ones carry no meaning in a sketch
            case label if label in DROPPED:
                return None
        return self.leaf(c, in_item)

    def arrange(self, comps: list[Comp], in_item: bool = False) -> list[Node]:
        """Lay out siblings with XY-cut, then group radios, merge switch labels and detect repetition."""
        placed = [
            Placed(c.box, n, c.label)
            for c in comps
            if c.w > 0 and c.h > 0 and (n := self.node(c, in_item)) is not None
        ]
        return finalize(xy_cut(placed)) if placed else []


@dataclass
class Placed:
    box: tuple[float, float, float, float]
    node: Node
    source: str


OVERLAP_TOLERANCE = 0.15  # boxes may overlap by 15% of their size and still count as separate bands


def _bands(items: list[Placed], axis: int) -> list[list[Placed]]:
    """Split items into bands along an axis (0 = x, 1 = y) wherever no item spans the gap."""
    lo, hi = axis, axis + 2
    ordered = sorted(items, key=lambda p: p.box[lo])
    bands = [[ordered[0]]]
    reach = ordered[0].box[hi]
    for p in ordered[1:]:
        size = p.box[hi] - p.box[lo]
        if reach - p.box[lo] <= OVERLAP_TOLERANCE * size:
            bands.append([p])
            reach = p.box[hi]
        else:
            bands[-1].append(p)
            reach = max(reach, p.box[hi])
    return bands


def _inside(a: Placed, b: Placed) -> bool:
    """True if a lies (>= 80%) inside b."""
    ix = max(0.0, min(a.box[2], b.box[2]) - max(a.box[0], b.box[0]))
    iy = max(0.0, min(a.box[3], b.box[3]) - max(a.box[1], b.box[1]))
    area = (a.box[2] - a.box[0]) * (a.box[3] - a.box[1])
    return area > 0 and ix * iy >= 0.8 * area


def xy_cut(items: list[Placed]) -> list[Node]:
    """Recursive XY-cut (classic document layout analysis); returns the children of a column.

    Cut into horizontal bands first (reading order is top-down); a band that cannot be cut further
    horizontally becomes a row of its vertical pieces, each of which is cut again.
    """
    if len(items) == 1:
        return [items[0].node]
    rows = _bands(items, axis=1)
    if len(rows) > 1:
        return [n for band in rows for n in xy_cut(band)]
    cols = _bands(items, axis=0)
    if len(cols) > 1:
        parts: list[Node] = []
        for piece in cols:
            sub = xy_cut(piece)
            node: Node = sub[0] if len(sub) == 1 else {"t": "col", "c": sub}
            parts.extend(node["c"] if node["t"] == "row" else [node])
        return [{"t": "row", "c": parts}]
    # Overlapping boxes: drop badges/overlays sitting on an image (play buttons, labels), then retry.
    kept = [
        p
        for p in items
        if not any(
            q is not p and q.node["t"] == "img" and p.node["t"] in ("icon", "img", "avatar") and _inside(p, q)
            for q in items
        )
    ]
    if 0 < len(kept) < len(items):
        return xy_cut(kept)
    return [p.node for p in sorted(items, key=lambda p: (p.box[1], p.box[0]))]


def finalize(nodes: list[Node]) -> list[Node]:
    """Post-process the children of a column (recursively): semantic grouping and repetition."""
    out = [_finalize_node(n) for n in nodes]
    return _collapse(_group_radios(out))


def _finalize_node(n: Node) -> Node:
    if n["t"] in ("col", "card"):
        return {**n, "c": finalize(n["c"])}
    if n["t"] == "row":
        kids = _merge_switch_label([_finalize_node(k) for k in n["c"]])
        if len(kids) == 1:
            return kids[0]
        if len(kids) <= 4 and all(k["t"] == "card" for k in kids) and len({signature(k) for k in kids}) == 1:
            return {"t": "grid", "cols": max(2, len(kids)), "n": len(kids), "item": kids[0]}
        return {"t": "row", "c": kids}
    if "item" in n:
        return {**n, "item": _finalize_node(n["item"])}
    return n


def _merge_switch_label(kids: list[Node]) -> list[Node]:
    """A settings row 'Wi-Fi ........ [switch]' is one switch whose label is the text."""
    if len(kids) == 2 and {kids[0]["t"], kids[1]["t"]} in ({"text", "switch"}, {"text", "check"}):
        text, ctl = (kids[0], kids[1]) if kids[0]["t"] == "text" else (kids[1], kids[0])
        return [{**ctl, "label": short(text["v"])}]
    return kids


def _group_radios(nodes: list[Node]) -> list[Node]:
    out: list[Node] = []
    for n in nodes:
        if n["t"] == "radio" and out and out[-1]["t"] == "radio" and len(out[-1]["options"]) < 6:
            out[-1] = {"t": "radio", "options": out[-1]["options"] + n["options"]}
        else:
            out.append(n)
    return out


def signature(n: Node) -> str:
    """Structure without text: repeated list items share a signature even when their content differs."""
    kids = n.get("c") or ([n["item"]] if "item" in n else [])
    extra = n.get("s", "") if n["t"] == "text" else ""
    return f"{n['t']}{extra}({','.join(signature(k) for k in kids)})"


def _contains_repeat(n: Node) -> bool:
    return n["t"] in ("list", "grid") or any(_contains_repeat(k) for k in n.get("c", []))


def _collapse(nodes: list[Node]) -> list[Node]:
    """Two or more consecutive identical composite items become one list; identical grids merge."""
    out: list[Node] = []
    i = 0
    while i < len(nodes):
        j = i + 1
        while j < len(nodes) and signature(nodes[j]) == signature(nodes[i]):
            j += 1
        n, run = nodes[i], j - i
        if run >= 2 and n["t"] == "grid":
            out.append({**n, "n": min(60, sum(m["n"] for m in nodes[i:j]))})
        elif run >= 2 and n["t"] in ("card", "row", "col") and not _contains_repeat(n):
            out.append({"t": "list", "n": min(50, run), "item": n})
        else:
            out.extend(nodes[i:j])
        i = j
    return out


MAX_ROW = 5  # wider rows are not realistically sketchable on a phone-sized frame


def sanitize(n: Node, depth: int = 1, in_repeat: bool = False) -> Node | None:
    """Make any converted tree satisfy the schema and semantic rules, whatever the source looked like."""
    t = n["t"]
    if depth > 9:
        return None
    if t == "radio":
        if len(n["options"]) < 2:
            return {"t": "check", "label": n["options"][0]}
        return {**n, "options": n["options"][:6]}
    if t in ("list", "grid"):
        item = sanitize(n["item"], depth + 1, True)
        if item is None:
            return None
        return item if in_repeat else {**n, "item": item}
    if t in ("col", "row", "card"):
        limit = MAX_ROW if t == "row" else 40
        kids = [k for c in n["c"] if (k := sanitize(c, depth + 1, in_repeat)) is not None][:limit]
        if not kids:
            return None
        if t != "card" and len(kids) == 1:
            return kids[0]
        return {**n, "c": kids}
    return n


def count_elements(n: Node) -> int:
    """Leaf elements a person would sketch (a list's item counts once)."""
    kids = n.get("c") or ([n["item"]] if "item" in n else [])
    return sum(count_elements(k) for k in kids) if kids else 1


@dataclass
class Result:
    spec: dict[str, Any] | None
    reason: str


def convert_screen(root: dict[str, Any], screen_id: str = "screen") -> Result:
    b = root.get("bounds") or [0, 0, 1440, 2560]
    width, height = float(b[2] - b[0]), float(b[3] - b[1])
    if width <= 0 or height <= width:
        return Result(None, "not_portrait")
    comps = parse_components(root)
    flat = list(_walk(comps))
    if any(c.label in OVERLAYS for c in flat):
        return Result(None, "overlay")
    texts = [clean_text(c.text) for c in flat if clean_text(c.text)]
    if texts and sum(not is_latin(t) for t in texts) > 0.3 * len(texts):
        return Result(None, "non_latin")

    conv = Converter(width, height, [c.h for c in flat if c.label == "Text" and clean_text(c.text)])
    toolbar = next((c for c in flat if c.label == "Toolbar" and c.box[1] < 0.15 * height), None)
    bottom = next((c for c in flat if c.label == "Bottom Navigation"), None)
    fab = next(
        (
            c
            for c in flat
            if c.label in ("Icon", "Image")
            and (c.icon in ("add", "edit"))
            and c.cx > 0.7 * width
            and c.cy > 0.75 * height
            and c.w < 0.2 * width
        ),
        None,
    )
    slot_ids = {id(c) for c in (toolbar, bottom, fab) if c is not None}
    for slot in (toolbar, bottom):
        if slot is not None:
            slot_ids |= {id(k) for k in _walk(slot.children)}

    screen: dict[str, Any] = {"id": screen_id, "title": "Screen"}
    if toolbar is not None:
        inner = list(_walk(toolbar.children))
        title = next((clean_text(k.text) for k in inner if k.label == "Text" and clean_text(k.text)), "")
        icons = [conv.icon_node(k) for k in inner if k.label == "Icon" and k.icon not in ("arrow_backward",)]
        appbar: dict[str, Any] = {
            "t": "appbar",
            "title": short(title) if title and is_latin(title) else "Screen",
        }
        icon_nodes = [i for i in icons if i["t"] == "icon"][:4]
        if icon_nodes:
            appbar["icons"] = icon_nodes
        screen["appbar"] = appbar
        screen["title"] = appbar["title"]

    body_comps = _strip(comps, slot_ids)
    body = sanitize({"t": "col", "c": conv.arrange(body_comps) or [{"t": "spacer"}]})
    if body is None or body["t"] == "spacer":
        return Result(None, "empty_body")
    screen["body"] = body if body["t"] in ("col", "list", "grid") else {"t": "col", "c": [body]}

    if bottom is not None:
        items: list[Node] = []
        for k in _walk(bottom.children):
            if k.label in ("Icon", "Image", "Text Button") and len(items) < 5:
                below = [
                    t for t in _walk(bottom.children) if t.label == "Text" and abs(t.cx - k.cx) < 0.08 * width
                ]
                label = clean_text(k.text) or next(
                    (clean_text(t.text) for t in below if clean_text(t.text)), ""
                )
                items.append(
                    {
                        "icon": ICON_MAP.get(k.icon or "", "circle"),
                        "label": short(label, 14) if label and is_latin(label) else f"Tab {len(items) + 1}",
                    }
                )
        if len(items) >= 2:
            screen["bottomnav"] = {"t": "bottomnav", "items": items}
    if fab is not None:
        screen["fab"] = {"t": "fab", "icon": ICON_MAP.get(fab.icon or "", "add")}

    n = (
        count_elements(screen["body"])
        + (1 if "appbar" in screen else 0)
        + (1 if "bottomnav" in screen else 0)
    )
    if not MIN_ELEMENTS <= n <= MAX_ELEMENTS:
        return Result(None, "too_few" if n < MIN_ELEMENTS else "too_many")
    spec = {"v": 1, "screens": [screen]}
    issues = validate(spec)
    if issues:
        return Result(None, f"invalid:{issues[0].code}")
    return Result(canonicalize(spec), "ok")


def _strip(comps: list[Comp], drop: set[int]) -> list[Comp]:
    out = []
    for c in comps:
        if id(c) in drop:
            continue
        c.children = _strip(c.children, drop)
        out.append(c)
    return out


def load_app_index(path: Path) -> dict[str, str]:
    """UI number -> app package name (needed to split by app and avoid leakage)."""
    with path.open(encoding="utf-8") as f:
        return {row["UI Number"]: row["App Package Name"] for row in csv.DictReader(f)}


def main() -> None:
    src = rico_dir() / "semantic_annotations"
    apps = load_app_index(rico_dir() / "ui_details.csv")
    out_dir = data_root() / "rico_specs"
    out_dir.mkdir(parents=True, exist_ok=True)
    reasons: Counter[str] = Counter()
    files = sorted(src.glob("*.json"), key=lambda p: int(p.stem))
    with (out_dir / "specs.jsonl").open("w", encoding="utf-8") as f:
        for path in files:
            try:
                root = json.loads(path.read_text(encoding="utf-8"))
                result = convert_screen(root)
            except (ValueError, KeyError, TypeError) as e:  # malformed source file
                reasons[f"error:{type(e).__name__}"] += 1
                continue
            reasons[result.reason] += 1
            if result.spec is not None:
                record = {"ui": path.stem, "app": apps.get(path.stem, "unknown"), "spec": result.spec}
                f.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")
    stats = {"source_screens": len(files), "reasons": dict(reasons.most_common())}
    (out_dir / "stats.json").write_text(json.dumps(stats, indent=1), encoding="utf-8")
    print(json.dumps(stats, indent=1))


if __name__ == "__main__":
    main()
