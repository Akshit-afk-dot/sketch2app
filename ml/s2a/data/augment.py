"""Legend-coverage augmentation: make every legend element frequent enough to learn.

RICO samples real apps, not sketch conventions. It has no divider label at all, and bottom navs, FABs,
radio groups and switches are rare (115 bottom navs in 42k screens). The recognizer cannot learn what it
never sees, so before sketching we insert these elements programmatically at the rates in
configs/data.yaml `augment`, with labels drawn from the corpus's own short labels. The gold spec is
derived from the augmented spec, so sketch and target stay consistent. No text is LLM-generated.
"""

from __future__ import annotations

import copy
import re
from typing import Any

import numpy as np

Node = dict[str, Any]
_WORD = re.compile(r"^[A-Za-z][A-Za-z &'-]{1,13}$")


def label_pool(specs: list[dict[str, Any]], limit: int = 5000) -> list[str]:
    """Short (1-2 word, <= 14 char) labels that already occur in the corpus, most frequent first."""
    counts: dict[str, int] = {}

    def visit(n: Any) -> None:
        if isinstance(n, dict):
            for key in ("label", "v", "title"):
                v = n.get(key)
                if isinstance(v, str) and _WORD.match(v) and len(v.split()) <= 2:
                    counts[v] = counts.get(v, 0) + 1
            for v in n.values():
                visit(v)
        elif isinstance(n, list):
            for v in n:
                visit(v)

    for s in specs:
        visit(s)
    return [w for w, _ in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))[:limit]]


def _words(rng: np.random.Generator, pool: list[str], k: int) -> list[str]:
    idx = rng.choice(len(pool), size=k, replace=False)
    return [pool[int(i)] for i in idx]


def augment_screen(rng: np.random.Generator, screen: Node, cfg: dict[str, float], pool: list[str]) -> Node:
    """Return a copy of [screen] with legend elements inserted at the configured rates."""
    s = copy.deepcopy(screen)
    body = s["body"]
    kids: list[Node] = body["c"] if body["t"] == "col" else [body]

    def insert(node: Node | list[Node]) -> None:
        nodes = node if isinstance(node, list) else [node]
        if len(kids) + len(nodes) > 40:
            return
        at = int(rng.integers(0, len(kids) + 1))
        kids[at:at] = nodes

    if len(pool) >= 8:
        if rng.random() < cfg["radio"]:
            insert({"t": "radio", "options": _words(rng, pool, int(rng.integers(2, 5)))})
        if rng.random() < cfg["switch"]:
            insert([{"t": "switch", "label": w} for w in _words(rng, pool, int(rng.integers(1, 4)))])
        if "bottomnav" not in s and rng.random() < cfg["bottomnav"]:
            items = [{"icon": "circle", "label": w} for w in _words(rng, pool, int(rng.integers(3, 6)))]
            s["bottomnav"] = {"t": "bottomnav", "items": items}
    if "fab" not in s and rng.random() < cfg["fab"]:
        s["fab"] = {"t": "fab", "icon": "add"}
    for i, k in enumerate(kids):
        if k["t"] == "list" and k["item"]["t"] == "card" and rng.random() < cfg["grid"]:
            cols = int(rng.integers(2, 4))
            kids[i] = {"t": "grid", "cols": cols, "n": cols * int(rng.integers(1, 4)), "item": k["item"]}
    if len(kids) >= 2 and rng.random() < cfg["divider"]:
        for _ in range(int(rng.integers(1, 3))):
            at = int(rng.integers(1, len(kids)))
            if kids[at - 1]["t"] != "divider" and kids[at]["t"] != "divider" and len(kids) < 40:
                kids.insert(at, {"t": "divider"})
    s["body"] = {"t": "col", "c": kids} if len(kids) > 1 or body["t"] == "col" else kids[0]
    return s
