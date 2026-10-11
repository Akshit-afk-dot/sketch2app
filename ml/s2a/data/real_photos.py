"""Photo study: import the app's export and score photo mode on real paper sketches.

    python -m s2a.data.real_photos import <sketch2app_photo_study.zip>
    python -m s2a.data.real_photos evaluate [--model recognizer_photo]

The target spec each participant drew is the label, so nobody draws boxes by hand. Two scores per photo:
  device  the app's own output on the phone (photo model, OCR labels, rule-based layout) against the
          target: tree similarity, type F1, link F1, screens correct, label accuracy, stage latencies.
  laptop  the same photos re-run here: JPEG -> grey (EXIF applied) -> the app's vectorizer (tool/batch.dart,
          compiled) -> ONNX recognizer (--model) -> rule-based layout (same binary). No OCR on the laptop,
          so labels are not scored; this compares recognizers and vectorizer changes on real photos.
Writes docs/results/photo_real_device.json and photo_real_laptop_<model>.json.
"""

from __future__ import annotations

import argparse
import json
import shutil
import statistics
import subprocess
import sys
import time
import zipfile
from pathlib import Path
from typing import Any

import numpy as np
from PIL import Image, ImageOps

from s2a.data.build_photo import vectorizer_exe
from s2a.data.photo import write_pgm
from s2a.layout.metrics import mean_scores, score
from s2a.paths import REPO_ROOT, data_root
from s2a.recognizer.decode import decode
from s2a.recognizer.features import ink_features

RESULTS = REPO_ROOT / "docs" / "results"
KEYS = ("id", "participant", "task", "photo", "target", "device")


def root() -> Path:
    return data_root() / "real" / "v1-photo"


def import_zip(src: Path) -> dict[str, int]:
    """Validate and store records + photos (repeated imports overwrite the same ids)."""
    out = root() / "records"
    out.mkdir(parents=True, exist_ok=True)
    report = {"imported": 0, "rejected": 0}
    with zipfile.ZipFile(src) as z:
        names = set(z.namelist())
        for n in sorted(names):
            if not n.endswith(".json"):
                continue
            rec = json.loads(z.read(n))
            photo = f"{Path(n).parent.as_posix()}/{rec.get('photo')}".lstrip("./")
            if any(k not in rec for k in KEYS) or photo not in names:
                report["rejected"] += 1
                print(f"rejected {n}: missing fields or photo", file=sys.stderr)
                continue
            (out / f"{rec['id']}.json").write_text(json.dumps(rec, ensure_ascii=False), encoding="utf-8")
            (out / rec["photo"]).write_bytes(z.read(photo))
            report["imported"] += 1
    return report


def _records() -> list[dict[str, Any]]:
    return [json.loads(p.read_text(encoding="utf-8")) for p in sorted((root() / "records").glob("*.json"))]


def _median(xs: list[float]) -> float | None:
    return statistics.median(xs) if xs else None


def evaluate_device(recs: list[dict[str, Any]]) -> dict[str, Any]:
    rows = [score(r["device"]["spec"], r["target"]) for r in recs]
    summary: dict[str, Any] = mean_scores(rows)
    dev = [r["device"] for r in recs]
    summary["latency_ms_median"] = {
        **{
            f"photo_{k}": _median([d["photo_micros"].get(k, 0) / 1000 for d in dev])
            for k in ("decode", "vectorize", "ocr")
        },
        **{
            k: _median([d["stage_ms"][k] for d in dev if k in d["stage_ms"]])
            for k in ("recognize", "handwriting", "layout")
        },
    }
    summary["fallbacks"] = {s: sum(s in d["fell_back"] for d in dev) for s in ("recognize", "layout")}
    summary["ocr_unavailable"] = sum(1 for d in dev if d.get("ocr_error"))
    summary["recognizers"] = sorted({d["recognizer"] for d in dev})
    return summary


def evaluate_laptop(recs: list[dict[str, Any]], model: str) -> dict[str, Any]:
    import onnxruntime as ort

    exe = vectorizer_exe()
    work = data_root() / "tmp_real_photo"
    shutil.rmtree(work, ignore_errors=True)
    for d in ("pgm", "vec", "elements", "specs"):
        (work / d).mkdir(parents=True)
    for r in recs:
        img = ImageOps.exif_transpose(Image.open(root() / "records" / r["photo"])).convert("L")
        write_pgm(work / "pgm" / f"{r['id']}.pgm", np.asarray(img, np.uint8))
    subprocess.run(
        [str(exe), "vectorize", str(work / "pgm"), str(work / "vec")], check=True, stdout=subprocess.DEVNULL
    )
    sess = ort.InferenceSession(
        str(REPO_ROOT / "app" / "assets" / "models" / f"{model}.onnx"), providers=["CPUExecutionProvider"]
    )
    ms: list[float] = []
    for r in recs:
        ink = json.loads((work / "vec" / f"{r['id']}.json").read_text(encoding="utf-8"))["ink"]
        t0 = time.perf_counter()
        if ink["strokes"]:
            shape, geom = ink_features(ink)
            c, t, a = (o[0] for o in sess.run(None, {"shape": shape[None], "geom": geom[None]}))
            elements = decode(ink, c, t, a)
        else:
            elements = {"v": 1, "frames": [], "elements": [], "arrows": []}
        ms.append((time.perf_counter() - t0) * 1000)
        (work / "elements" / f"{r['id']}.json").write_text(json.dumps(elements), encoding="utf-8")
    subprocess.run(
        [str(exe), "layout", str(work / "elements"), str(work / "specs")],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    rows = []
    for r in recs:
        p = work / "specs" / f"{r['id']}.json"
        rows.append(score(p.read_text(encoding="utf-8") if p.exists() else None, r["target"]))
    summary: dict[str, Any] = mean_scores(rows)
    summary.pop("label_accuracy", None)  # no OCR here: labels are generic placeholders
    summary["recognizer_ms_median"] = _median(ms)
    return summary


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("command", choices=["import", "evaluate"])
    ap.add_argument("src", nargs="?", type=Path, help="import: the zip exported by Photo study")
    ap.add_argument("--model", default="recognizer_photo", help="laptop re-run: app model asset name")
    args = ap.parse_args()
    if args.command == "import":
        if args.src is None:
            ap.error("import needs the exported zip")
        print(json.dumps(import_zip(args.src), indent=1))
        return
    recs = _records()
    if not recs:
        sys.exit(f"no records under {root()}: import a Photo study export first")
    meta = {
        "photos": len(recs),
        "participants": len({r["participant"] for r in recs}),
        "tasks": len({r["task"] for r in recs}),
        "date": time.strftime("%Y-%m-%d"),
    }
    RESULTS.mkdir(parents=True, exist_ok=True)
    device = {**evaluate_device(recs), "meta": meta}
    (RESULTS / "photo_real_device.json").write_text(json.dumps(device, indent=1), encoding="utf-8")
    laptop = {**evaluate_laptop(recs, args.model), "meta": {**meta, "model": args.model}}
    (RESULTS / f"photo_real_laptop_{args.model}.json").write_text(
        json.dumps(laptop, indent=1), encoding="utf-8"
    )
    print(json.dumps({"device": device, "laptop": laptop}, indent=1))


if __name__ == "__main__":
    main()
