"""End-to-end evaluation on synthetic test sketches, run on the laptop.

    python -m s2a.e2e --n 200 --analyze 20 [--layout heuristic | --pred <llm predictions jsonl> --name NAME]

ink -> learned recognizer (ONNX) -> labels -> layout -> spec -> render check -> export + `flutter analyze`.
Labels come from the gold elements matched to recognized ones (s2a.layout.recognized), i.e. a perfect
handwriting reader: ML Kit only runs on Android, so handwriting is measured on the device, not here.
Writes docs/results/e2e_<name>_test.json.
"""

from __future__ import annotations

import argparse
import json
import shutil
import statistics
import subprocess
import time
from pathlib import Path
from typing import Any

from s2a.data.build_dataset import out_root
from s2a.layout.metrics import parse_output
from s2a.paths import REPO_ROOT, data_root
from s2a.spec import canonical_json, validate

APP = REPO_ROOT / "app"


def _run(cmd: list[str], env: dict[str, str] | None = None) -> None:
    import os

    subprocess.run(cmd, cwd=APP, check=True, shell=True, env={**os.environ, **(env or {})})


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=200)
    ap.add_argument("--analyze", type=int, default=20, help="exported projects to run flutter analyze on")
    ap.add_argument(
        "--pred", type=Path, help="LLM predictions JSONL (recognizer input); default: rule-based layout"
    )
    ap.add_argument("--name", default="heuristic")
    args = ap.parse_args()

    work = data_root() / "e2e" / args.name
    shutil.rmtree(work, ignore_errors=True)
    (work / "elements").mkdir(parents=True)
    (work / "specs").mkdir()
    recognized = [
        json.loads(line)
        for line in (out_root() / "eval" / "test" / "recognized.jsonl").open(encoding="utf-8")
    ]
    recognized = recognized[: args.n]
    rec_meta = json.loads(
        (REPO_ROOT / "docs" / "results" / "recognizer_onnx_test.json").read_text(encoding="utf-8")
    )["meta"]

    t0 = time.perf_counter()
    layout_ms: list[float] = []
    if args.pred:
        outputs = {r["id"]: r for r in map(json.loads, args.pred.open(encoding="utf-8"))}
        for r in recognized:
            o = outputs.get(r["id"])
            spec = parse_output(o["output"]) if o else None
            if spec is not None and not validate(spec):
                (work / "specs" / f"{r['id']}.json").write_text(canonical_json(spec), encoding="utf-8")
            if o and o.get("ms") == o.get("ms"):
                layout_ms.append(float(o["ms"]))
    else:
        for r in recognized:
            (work / "elements" / f"{r['id']}.json").write_text(json.dumps(r["elements"]), encoding="utf-8")
        _run(["dart", "run", "tool/batch.dart", "layout", str(work / "elements"), str(work / "specs")])
        timings = json.loads((work / "specs" / "_timings.json").read_text(encoding="utf-8"))["files"]
        layout_ms = [v / 1000 for v in timings.values()]
        (work / "specs" / "_timings.json").unlink()
    valid = sorted(work.glob("specs/*.json"))

    _run(
        ["flutter", "test", "--suppress-analytics", "test/render_specs_test.dart"],
        {"S2A_RENDER_DIR": str(work / "specs")},
    )
    render = json.loads((work / "specs" / "_render.json").read_text(encoding="utf-8"))

    sub = work / "export_subset"
    sub.mkdir()
    for f in valid[: args.analyze]:
        shutil.copy(f, sub / f.name)
    report = work / "export_check.json"
    _run(
        [
            "dart",
            "run",
            "tool/export_examples.dart",
            "--specs",
            str(sub),
            "--out",
            str(work / "exports"),
            "--report",
            str(report),
        ]
    )
    export = json.loads(report.read_text(encoding="utf-8"))["summary"]

    result: dict[str, Any] = {
        "sketches": len(recognized),
        "spec_valid_rate": len(valid) / len(recognized),
        "render_success_rate": sum(1 for v in render.values() if v["rendered"]) / len(recognized),
        "render_errors": sorted({v["error"] for v in render.values() if v.get("error")})[:10],
        "exported_analyze_pass": f"{export['analyze_pass']}/{export['projects']}",
        "laptop_ms_median": {
            "recognizer": rec_meta["laptop_ms_per_sketch"]["median"],
            "layout": statistics.median(layout_ms) if layout_ms else None,
        },
        "handwriting": "oracle (gold labels); ML Kit is measured on the device",
        "layout": args.name,
        "seconds": round(time.perf_counter() - t0, 1),
    }
    path = REPO_ROOT / "docs" / "results" / f"e2e_{args.name}_test.json"
    path.write_text(json.dumps(result, indent=1), encoding="utf-8")
    print(json.dumps(result, indent=1))


if __name__ == "__main__":
    main()
