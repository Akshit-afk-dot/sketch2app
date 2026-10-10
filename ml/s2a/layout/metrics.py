"""Layout metrics: compare a predicted UI spec (raw model text) with the gold spec.

- json_valid / schema_valid: does the output parse, and does it pass the full validator?
- tree_similarity: 1 - TED / max(|T_pred|, |T_gold|) with APTED (unit costs) on a structural tree:
  node labels are types (text with its style, icons with their name), not strings, so the metric
  measures layout structure; labels are scored separately.
- type_f1: F1 between the multisets of leaf element types (did we produce the right kinds of things?)
- link_f1: F1 between multisets of navigation links (source element kind+label -> target screen index),
  only for samples whose gold spec has links (otherwise None, and excluded from the mean)
- label_accuracy: fraction of gold text labels that appear verbatim among predicted labels
An invalid output scores 0 on everything except json_valid.
"""

from __future__ import annotations

import json
from collections import Counter
from dataclasses import dataclass, field
from typing import Any

from apted import APTED

from s2a.spec import validate


@dataclass
class TNode:
    name: str
    children: list[TNode] = field(default_factory=list)

    def size(self) -> int:
        return 1 + sum(c.size() for c in self.children)


def _label(n: dict[str, Any]) -> str:
    t = n["t"]
    if t == "text":
        return f"text:{n.get('s', 'body')}"
    if t == "btn":
        return f"btn:{n.get('variant', 'primary')}"
    if t == "icon":
        return f"icon:{n['name']}"
    return str(t)


def _node(n: dict[str, Any]) -> TNode:
    kids = n.get("c") or ([n["item"]] if "item" in n else [])
    return TNode(_label(n), [_node(k) for k in kids])


def spec_tree(spec: dict[str, Any]) -> TNode:
    screens = []
    for s in spec["screens"]:
        kids = []
        if "appbar" in s:
            kids.append(TNode("appbar", [_node(i) for i in s["appbar"].get("icons", [])]))
        kids.append(TNode("body", [_node(s["body"])]))
        if "bottomnav" in s:
            kids.append(TNode("bottomnav", [TNode("navitem") for _ in s["bottomnav"]["items"]]))
        if "fab" in s:
            kids.append(TNode("fab"))
        screens.append(TNode("screen", kids))
    return TNode("app", screens)


def tree_similarity(pred: dict[str, Any], gold: dict[str, Any]) -> float:
    a, b = spec_tree(pred), spec_tree(gold)
    ted = float(APTED(a, b).compute_edit_distance())
    return 1.0 - ted / max(a.size(), b.size())


def _walk(n: Any) -> list[dict[str, Any]]:
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


def leaf_types(spec: dict[str, Any]) -> Counter[str]:
    c: Counter[str] = Counter()
    for s in spec["screens"]:
        for d in _walk(s["body"]):
            if "t" in d and not d.get("c") and "item" not in d:
                c[_label(d)] += 1
        for slot in ("appbar", "bottomnav", "fab"):
            if slot in s:
                c[slot] += 1
    return c


def links(spec: dict[str, Any]) -> Counter[tuple[str, str, int]]:
    index = {s["id"]: k for k, s in enumerate(spec["screens"])}
    out: Counter[tuple[str, str, int]] = Counter()
    for s in spec["screens"]:
        for d in _walk(s):
            if "go" in d and d["go"] in index:
                kind = d.get("t", "navitem")
                label = str(d.get("label") or d.get("v") or "")
                out[(kind, label, index[d["go"]])] += 1
    return out


def labels(spec: dict[str, Any]) -> Counter[str]:
    out: Counter[str] = Counter()
    for d in _walk(spec):
        for key in ("label", "v", "title"):
            if isinstance(d.get(key), str):
                out[d[key]] += 1
    return out


def _f1(pred: Counter[Any], gold: Counter[Any]) -> float:
    if not pred and not gold:
        return 1.0
    tp = sum((pred & gold).values())
    p = tp / sum(pred.values()) if pred else 0.0
    r = tp / sum(gold.values()) if gold else 0.0
    return 2 * p * r / (p + r) if p + r else 0.0


def parse_output(text: str) -> dict[str, Any] | None:
    """The model's text -> JSON object, tolerating surrounding prose or a code fence."""
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end <= start:
        return None
    try:
        obj = json.loads(text[start : end + 1])
    except json.JSONDecodeError:
        return None
    return obj if isinstance(obj, dict) else None


def score(pred_text: str | dict[str, Any] | None, gold: dict[str, Any]) -> dict[str, float | None]:
    pred = parse_output(pred_text) if isinstance(pred_text, str) else pred_text
    gold_links = links(gold)
    metrics = (
        "json_valid",
        "schema_valid",
        "tree_similarity",
        "type_f1",
        "link_f1",
        "label_accuracy",
        "screens_correct",
    )
    zero: dict[str, float | None] = dict.fromkeys(metrics, 0.0)
    if not gold_links:
        zero["link_f1"] = None
    if pred is None:
        return zero
    out = dict(zero, json_valid=1.0)
    if validate(pred):
        return out
    gold_labels = labels(gold)
    hit = sum((labels(pred) & gold_labels).values())
    out.update(
        schema_valid=1.0,
        tree_similarity=tree_similarity(pred, gold),
        type_f1=_f1(leaf_types(pred), leaf_types(gold)),
        link_f1=_f1(links(pred), gold_links) if gold_links else None,
        label_accuracy=hit / sum(gold_labels.values()) if gold_labels else 1.0,
        screens_correct=float(len(pred["screens"]) == len(gold["screens"])),
    )
    return out


def mean_scores(rows: list[dict[str, float | None]]) -> dict[str, float]:
    """Mean of each metric over the samples where it is defined; n_<metric> says how many."""
    out: dict[str, float] = {}
    for k in rows[0] if rows else []:
        vals = [v for r in rows if (v := r[k]) is not None]
        out[k] = sum(vals) / len(vals) if vals else float("nan")
        if len(vals) != len(rows):
            out[f"n_{k}"] = len(vals)
    return out
