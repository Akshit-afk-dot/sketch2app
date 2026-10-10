"""Recognizer metrics, applied identically to the learned model and the heuristic baseline.

- stroke-class accuracy (frame / text / shape / arrow), with a per-class confusion matrix;
- element detection: a predicted element matches a gold one when IoU >= 0.5 (greedy, highest IoU first);
  reported both type-agnostic ("found the thing") and typed ("found it and named it right");
- per-type confusion matrix over IoU-matched pairs, which shows *which* types get confused.
"""

from __future__ import annotations

from collections import Counter
from dataclasses import dataclass, field
from typing import Any

from s2a.recognizer.labels import ELEMENT_TYPES, STROKE_CLASSES


def iou(a: list[float], b: list[float], pad: float = 2.0) -> float:
    """IoU of [x, y, w, h] boxes after padding both by [pad] px, so zero-height lines can still match."""
    ax0, ay0, ax1, ay1 = a[0] - pad, a[1] - pad, a[0] + a[2] + pad, a[1] + a[3] + pad
    bx0, by0, bx1, by1 = b[0] - pad, b[1] - pad, b[0] + b[2] + pad, b[1] + b[3] + pad
    inter = max(0.0, min(ax1, bx1) - max(ax0, bx0)) * max(0.0, min(ay1, by1) - max(ay0, by0))
    union = (ax1 - ax0) * (ay1 - ay0) + (bx1 - bx0) * (by1 - by0) - inter
    return inter / union if union > 0 else 0.0


def match(pred: list[dict[str, Any]], gold: list[dict[str, Any]], thr: float = 0.5) -> list[tuple[int, int]]:
    pairs = sorted(
        ((iou(p["box"], g["box"]), i, j) for i, p in enumerate(pred) for j, g in enumerate(gold)),
        reverse=True,
    )
    used_p: set[int] = set()
    used_g: set[int] = set()
    out = []
    for v, i, j in pairs:
        if v < thr:
            break
        if i in used_p or j in used_g:
            continue
        used_p.add(i)
        used_g.add(j)
        out.append((i, j))
    return out


@dataclass
class DetectionStats:
    tp_any: int = 0
    tp_typed: int = 0
    n_pred: int = 0
    n_gold: int = 0
    confusion: Counter[tuple[str, str]] = field(default_factory=Counter)  # (gold, pred)
    stroke_correct: int = 0
    stroke_total: int = 0
    stroke_confusion: Counter[tuple[str, str]] = field(default_factory=Counter)

    def add(self, pred: list[dict[str, Any]], gold: list[dict[str, Any]]) -> None:
        pairs = match(pred, gold)
        self.n_pred += len(pred)
        self.n_gold += len(gold)
        self.tp_any += len(pairs)
        for i, j in pairs:
            self.confusion[(gold[j]["type"], pred[i]["type"])] += 1
            self.tp_typed += pred[i]["type"] == gold[j]["type"]

    def add_strokes(self, pred_cls: list[str], gold_cls: list[str]) -> None:
        for p, g in zip(pred_cls, gold_cls, strict=True):
            self.stroke_total += 1
            self.stroke_correct += p == g
            self.stroke_confusion[(g, p)] += 1

    def summary(self) -> dict[str, Any]:
        def prf(tp: int) -> dict[str, float]:
            p = tp / self.n_pred if self.n_pred else 0.0
            r = tp / self.n_gold if self.n_gold else 0.0
            return {"precision": p, "recall": r, "f1": 2 * p * r / (p + r) if p + r else 0.0}

        per_type = {}
        for t in ELEMENT_TYPES:
            gold_t = sum(v for (g, _), v in self.confusion.items() if g == t)
            correct = self.confusion.get((t, t), 0)
            per_type[t] = {"matched_gold": gold_t, "type_accuracy": correct / gold_t if gold_t else None}
        return {
            "elements_gold": self.n_gold,
            "elements_pred": self.n_pred,
            "detection_any_type": prf(self.tp_any),
            "detection_typed": prf(self.tp_typed),
            "stroke_accuracy": self.stroke_correct / self.stroke_total if self.stroke_total else None,
            "per_type": per_type,
            "confusion": {f"{g}->{p}": v for (g, p), v in sorted(self.confusion.items())},
            "stroke_confusion": {f"{g}->{p}": v for (g, p), v in sorted(self.stroke_confusion.items())},
        }


def stroke_classes_from_elements(n_strokes: int, el: dict[str, Any]) -> list[str]:
    """Per-stroke class implied by an element list (used for baselines that do not label strokes):
    text if in some element's text_strokes, arrow if in an arrow, shape if in an element, else frame."""
    cls = ["frame"] * n_strokes
    for e in el["elements"]:
        for i in e.get("strokes", []):
            cls[i] = "shape"
        for i in e.get("text_strokes", []):
            cls[i] = "text"
    for a in el["arrows"]:
        for i in a.get("strokes", []):
            cls[i] = "arrow"
    assert all(c in STROKE_CLASSES for c in cls)
    return cls
