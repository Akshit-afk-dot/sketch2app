"""Model outputs -> element list (elements.v1). Reference implementation for the Dart decoder.

Grouping is average-linkage agglomerative clustering on the predicted pairwise "same group"
probabilities: repeatedly merge the two clusters whose average affinity is highest, while it exceeds
the threshold. Average linkage resists chaining (one confident wrong edge cannot glue two elements
together, unlike connected components on a thresholded graph).
"""

from __future__ import annotations

from typing import Any

import numpy as np

from s2a.recognizer.labels import ELEMENT_TYPES, NONE_TYPE, STROKE_CLASSES

FRAME, TEXT, SHAPE, ARROW = (STROKE_CLASSES.index(c) for c in ("frame", "text", "shape", "arrow"))


def softmax(x: np.ndarray) -> np.ndarray:
    e = np.exp(x - x.max(axis=-1, keepdims=True))
    out: np.ndarray = e / e.sum(axis=-1, keepdims=True)
    return out


def sigmoid(x: np.ndarray) -> np.ndarray:
    out: np.ndarray = 1 / (1 + np.exp(-x))
    return out


def cluster(prob: np.ndarray, threshold: float = 0.5) -> list[list[int]]:
    """Average-linkage clustering; prob is a symmetric (S, S) matrix of same-group probabilities."""
    n = len(prob)
    clusters: list[list[int]] = [[i] for i in range(n)]
    sums = prob.astype(np.float64).copy()  # sum of pairwise probabilities between clusters
    np.fill_diagonal(sums, -np.inf)
    sizes = np.ones(n)
    alive = np.ones(n, dtype=bool)
    while True:
        avg = sums / np.outer(sizes, sizes)
        avg[~alive, :] = -np.inf
        avg[:, ~alive] = -np.inf
        i, j = np.unravel_index(int(np.argmax(avg)), avg.shape)
        if avg[i, j] <= threshold:
            break
        i, j = (i, j) if i < j else (j, i)
        clusters[i] += clusters[j]
        clusters[j] = []
        sums[i, :] += sums[j, :]
        sums[:, i] += sums[:, j]
        sums[i, i] = -np.inf
        sizes[i] += sizes[j]
        alive[j] = False
    return [sorted(c) for c in clusters if c]


def _box(strokes: list[list[list[float]]]) -> list[float]:
    pts = np.array([p[:2] for s in strokes for p in s], dtype=np.float64)
    x0, y0 = pts.min(axis=0)
    x1, y1 = pts.max(axis=0)
    return [float(x0), float(y0), float(x1 - x0), float(y1 - y0)]


def _inside(box: list[float], frame: list[float]) -> bool:
    cx, cy = box[0] + box[2] / 2, box[1] + box[3] / 2
    return frame[0] <= cx <= frame[0] + frame[2] and frame[1] <= cy <= frame[1] + frame[3]


def _arrow_ends(strokes: list[list[list[float]]]) -> tuple[list[float], list[float]]:
    """Shaft = longest stroke. Head = the shaft end nearest the other (head) strokes, else its last point."""
    lengths = [
        sum(np.hypot(*np.subtract(s[k + 1][:2], s[k][:2])) for k in range(len(s) - 1)) for s in strokes
    ]
    shaft = strokes[int(np.argmax(lengths))]
    a, b = shaft[0][:2], shaft[-1][:2]
    others = [p[:2] for s in strokes if s is not shaft for p in s]
    if others:
        c = np.mean(others, axis=0)
        if np.hypot(*(np.subtract(a, c))) < np.hypot(*(np.subtract(b, c))):
            a, b = b, a
    return [float(a[0]), float(a[1])], [float(b[0]), float(b[1])]


def decode(
    ink: dict[str, Any],
    cls_logits: np.ndarray,
    type_logits: np.ndarray,
    aff_logits: np.ndarray,
    threshold: float = 0.5,
) -> dict[str, Any]:
    strokes = [s["pts"] for s in ink["strokes"]]
    cls_p = softmax(cls_logits)
    type_p = softmax(type_logits)
    groups = cluster(sigmoid(aff_logits), threshold) if len(strokes) else []

    frames = [{"id": f["id"], "box": list(f["box"])} for f in ink.get("frames", [])]
    elements: list[dict[str, Any]] = []
    arrows: list[dict[str, Any]] = []
    pending: list[tuple[list[int], int]] = []
    for g in groups:
        kind = int(np.argmax(cls_p[g].sum(axis=0)))
        if kind == FRAME:
            frames.append({"id": len(frames), "box": _box([strokes[i] for i in g]), "strokes": g})
        elif kind == ARROW:
            tail, head = _arrow_ends([strokes[i] for i in g])
            arrows.append({"id": len(arrows), "strokes": g, "tail": tail, "head": head})
        else:
            scores = type_p[g].sum(axis=0)
            scores[NONE_TYPE] = -1
            pending.append((g, int(np.argmax(scores))))
    for g, t in pending:
        box = _box([strokes[i] for i in g])
        el: dict[str, Any] = {"id": len(elements), "type": ELEMENT_TYPES[t], "box": box, "strokes": g}
        frame = next((f["id"] for f in frames if _inside(box, f["box"])), None)
        if frame is not None:
            el["frame"] = frame
        text = [i for i in g if int(np.argmax(cls_p[i])) == TEXT]
        if text:
            el["text_strokes"] = text
        el["score"] = float(type_p[g].max(axis=1).mean())
        elements.append(el)
    return {"v": 1, "frames": frames, "elements": elements, "arrows": arrows}
