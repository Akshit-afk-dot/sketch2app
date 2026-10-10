"""Evaluate a recognizer on the exported eval sketches; writes docs/results/recognizer_<name>_<split>.json.

    python -m s2a.recognizer.evaluate --method heuristic --split test     # the app's Dart rules
    python -m s2a.recognizer.evaluate --method onnx --data real --split test  # held-out real sketches
    python -m s2a.recognizer.evaluate --method onnx --split test          # app/assets/models/recognizer.onnx
    python -m s2a.recognizer.evaluate --method torch --ckpt <run>/best.pt --split val

Both methods are scored by the same code (metrics.py) against the same gold element lists. The
heuristic is run through `dart run tool/batch.dart`, i.e. exactly the code that ships in the app.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any

import numpy as np

from s2a.data.collected import eval_root
from s2a.paths import REPO_ROOT
from s2a.recognizer.decode import decode
from s2a.recognizer.features import ink_features
from s2a.recognizer.labels import STROKE_CLASSES
from s2a.recognizer.metrics import DetectionStats, stroke_classes_from_elements

RESULTS = REPO_ROOT / "docs" / "results"


def _gold(ink: Path) -> dict[str, Any]:
    gold: dict[str, Any] = json.loads((ink.parent.parent / "gold" / ink.name).read_text(encoding="utf-8"))
    return gold


def eval_heuristic(inks: list[Path]) -> tuple[DetectionStats, list[float]]:
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp)
        subprocess.run(
            ["dart", "run", "tool/batch.dart", "recognize", str(inks[0].parent), str(out)],
            cwd=REPO_ROOT / "app",
            check=True,
            shell=True,
        )
        times = json.loads((out / "_timings.json").read_text(encoding="utf-8"))["files"]
        stats = DetectionStats()
        ms = []
        for f in inks:
            pred = json.loads((out / f.name).read_text(encoding="utf-8"))
            gold = _gold(f)
            n = len(gold["stroke_cls"])
            stats.add(pred["elements"], gold["elements"]["elements"])
            stats.add_strokes(stroke_classes_from_elements(n, pred), gold["stroke_cls"])
            ms.append(times[f.name] / 1000)
    return stats, ms


def eval_model(
    inks: list[Path], method: str, ckpt: Path | None, threshold: float
) -> tuple[DetectionStats, list[float]]:
    if method == "onnx":
        import onnxruntime as ort

        sess = ort.InferenceSession(
            str(REPO_ROOT / "app" / "assets" / "models" / "recognizer.onnx"),
            providers=["CPUExecutionProvider"],
        )

        def run(shape: np.ndarray, geom: np.ndarray) -> list[np.ndarray]:
            return [o[0] for o in sess.run(None, {"shape": shape[None], "geom": geom[None]})]
    else:
        import torch

        from s2a.recognizer.export import Single, load

        model = Single(load(ckpt)).eval()

        def run(shape: np.ndarray, geom: np.ndarray) -> list[np.ndarray]:
            with torch.no_grad():
                return [
                    o[0].numpy() for o in model(torch.from_numpy(shape)[None], torch.from_numpy(geom)[None])
                ]

    stats, ms = DetectionStats(), []
    for f in inks:
        ink = json.loads(f.read_text(encoding="utf-8"))
        gold = _gold(f)
        t0 = time.perf_counter()
        shape, geom = ink_features(ink)
        c, t, a = run(shape, geom)
        pred = decode(ink, c, t, a, threshold)
        ms.append((time.perf_counter() - t0) * 1000)
        stats.add(pred["elements"], gold["elements"]["elements"])
        stats.add_strokes([STROKE_CLASSES[i] for i in c.argmax(axis=1)], gold["stroke_cls"])
    return stats, ms


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--method", choices=["heuristic", "onnx", "torch"], required=True)
    ap.add_argument("--split", default="test", choices=["val", "test"])
    ap.add_argument("--data", default="synth", choices=["synth", "real"])
    ap.add_argument("--ckpt", type=Path)
    ap.add_argument("--name", help="result name (default: method)")
    ap.add_argument("--threshold", type=float, default=0.5)
    args = ap.parse_args()
    inks = sorted(f for f in (eval_root(args.data) / args.split / "ink").glob("*.json"))
    inks = [f for f in inks if json.loads(f.read_text(encoding="utf-8"))["strokes"]]
    if args.method == "heuristic":
        stats, ms = eval_heuristic(inks)
    else:
        stats, ms = eval_model(inks, args.method, args.ckpt, args.threshold)
    summary = stats.summary()
    summary["meta"] = {
        "method": args.method,
        "split": args.split,
        "data": args.data,
        "sketches": len(inks),
        "checkpoint": str(args.ckpt) if args.ckpt else None,
        "laptop_ms_per_sketch": {"median": float(np.median(ms)), "p90": float(np.percentile(ms, 90))},
        "date": time.strftime("%Y-%m-%d"),
    }
    RESULTS.mkdir(parents=True, exist_ok=True)
    suffix = args.split if args.data == "synth" else f"real_{args.split}"
    path = RESULTS / f"recognizer_{args.name or args.method}_{suffix}.json"
    path.write_text(json.dumps(summary, indent=1), encoding="utf-8")
    keys = ("detection_any_type", "detection_typed", "stroke_accuracy", "meta")
    print(json.dumps({k: summary[k] for k in keys}, indent=1))


if __name__ == "__main__":
    main()
