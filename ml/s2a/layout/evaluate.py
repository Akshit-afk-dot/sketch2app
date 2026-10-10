"""Evaluate layout methods on eval sketches; writes docs/results/layout_<method>_<input>_<split>.json.

    python -m s2a.layout.evaluate --method heuristic --input gold --split test
    python -m s2a.layout.evaluate --method predictions --pred preds.jsonl --input gold --split test

Inputs: `gold` = the gold element list with gold labels (layout stage in isolation, perfect recognition
and handwriting); `recognizer` = elements predicted by the trained recognizer with labels copied from
matched gold elements (recognition errors included, handwriting assumed correct).
Methods: `heuristic` = the app's Dart builder (tool/batch.dart layout); `predictions` = a JSONL of model
outputs {"id": ..., "output": "<raw text>"} produced by the LLM notebook or the LAN server.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any

from s2a.data.build_dataset import out_root
from s2a.layout.metrics import mean_scores, score
from s2a.paths import REPO_ROOT

RESULTS = REPO_ROOT / "docs" / "results"


def load_inputs(split: str, kind: str) -> dict[str, dict[str, Any]]:
    """id -> elements.v1 input for the layout stage."""
    if kind == "gold":
        out = {}
        for p in sorted((out_root() / "eval" / split / "gold").glob("*.json")):
            g = json.loads(p.read_text(encoding="utf-8"))
            out[p.stem] = g["elements"]
        return out
    path = out_root() / "eval" / split / "recognized.jsonl"
    if not path.exists():
        raise SystemExit(f"{path} missing: run python -m s2a.layout.recognized --split {split}")
    return {r["id"]: r["elements"] for r in map(json.loads, path.open(encoding="utf-8"))}


def gold_specs(split: str) -> dict[str, dict[str, Any]]:
    return {
        p.stem: json.loads(p.read_text(encoding="utf-8"))["spec"]
        for p in sorted((out_root() / "eval" / split / "gold").glob("*.json"))
    }


def run_heuristic(inputs: dict[str, dict[str, Any]]) -> tuple[dict[str, str], dict[str, float]]:
    with tempfile.TemporaryDirectory() as tmp:
        src, dst = Path(tmp) / "in", Path(tmp) / "out"
        src.mkdir()
        for k, el in inputs.items():
            (src / f"{k}.json").write_text(json.dumps(el), encoding="utf-8")
        subprocess.run(
            ["dart", "run", "tool/batch.dart", "layout", str(src), str(dst)],
            cwd=REPO_ROOT / "app",
            check=True,
            shell=True,
        )
        timings = json.loads((dst / "_timings.json").read_text(encoding="utf-8"))["files"]
        outs = {
            k: (dst / f"{k}.json").read_text(encoding="utf-8") for k in inputs if (dst / f"{k}.json").exists()
        }
    return outs, {k.removesuffix(".json"): v / 1000 for k, v in timings.items()}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--method", choices=["heuristic", "predictions"], required=True)
    ap.add_argument("--input", choices=["gold", "recognizer"], default="gold")
    ap.add_argument("--split", choices=["val", "test"], default="test")
    ap.add_argument("--pred", type=Path, help="JSONL of model outputs (method=predictions)")
    ap.add_argument("--name", help="result name (default: method)")
    args = ap.parse_args()
    inputs = load_inputs(args.split, args.input)
    golds = gold_specs(args.split)
    ms: dict[str, float] = {}
    if args.method == "heuristic":
        outputs, ms = run_heuristic(inputs)
    else:
        outputs = {r["id"]: r["output"] for r in map(json.loads, args.pred.open(encoding="utf-8"))}
        ms = {r["id"]: r.get("ms", float("nan")) for r in map(json.loads, args.pred.open(encoding="utf-8"))}
    rows = [score(outputs.get(k), golds[k]) for k in sorted(inputs)]
    summary: dict[str, Any] = mean_scores(rows)
    times = sorted(v for v in ms.values() if v == v)
    summary["meta"] = {
        "method": args.method,
        "name": args.name or args.method,
        "input": args.input,
        "split": args.split,
        "samples": len(rows),
        "ms_per_sample_median": times[len(times) // 2] if times else None,
        "date": time.strftime("%Y-%m-%d"),
    }
    RESULTS.mkdir(parents=True, exist_ok=True)
    path = RESULTS / f"layout_{args.name or args.method}_{args.input}_{args.split}.json"
    path.write_text(json.dumps(summary, indent=1), encoding="utf-8")
    print(json.dumps(summary, indent=1))


if __name__ == "__main__":
    main()
