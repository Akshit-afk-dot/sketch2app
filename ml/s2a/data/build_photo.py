"""Build the synthetic-photo dataset that the photo recognizer is trained and evaluated on (P11).

    python -m s2a.data.build_photo [--limit N] [--workers 8]

Same specs and by-app splits as v1, but phone outlines are drawn (always for 2-3 screens; with
`single_frame_drawn_prob` for one, otherwise the page is the screen, as on paper). Per chunk of shards:
render photos (photo.render) -> the app's vectorizer, compiled once from tool/batch.dart and run in
parallel processes -> label pseudo-strokes (photo.label) -> shard. Photos are deleted after vectorizing,
except in the eval exports, which keep a PNG per sample.

Output $S2A_DATA_ROOT/synth/v1-photo/ mirrors v1 ({train,val,test}/shard_*.jsonl.gz, eval/{val,test}/
{ink,gold,photo}/, stats.json), so every v1 tool runs on it with S2A_DATASET=v1-photo.
"""

from __future__ import annotations

import argparse
import copy
import gzip
import json
import os
import pickle
import shutil
import subprocess
from collections import Counter
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
from typing import Any

import numpy as np
import yaml
from PIL import Image

from s2a.data.augment import label_pool
from s2a.data.build_dataset import CONFIG, SPLITS, plan, split_of
from s2a.data.photo import label, label_map, render, write_pgm
from s2a.data.synth import make_sample
from s2a.paths import REPO_ROOT, data_root

DATASET = "v1-photo"
PHOTO_SEED = 7  # extra seed component: photo samples differ from the v1 sample with the same index


def root() -> Path:
    return data_root() / "synth" / DATASET


def vectorizer_exe() -> Path:
    """tool/batch.dart compiled ahead of time: one binary for all workers (parallel `dart run` processes
    would race on the package's build cache) and AOT speed, close to the release app's."""
    exe = data_root() / "bin" / "s2a_batch.exe"
    sources = [REPO_ROOT / "app" / "tool" / "batch.dart", *(REPO_ROOT / "app" / "lib").rglob("*.dart")]
    if not exe.exists() or exe.stat().st_mtime < max(p.stat().st_mtime for p in sources):
        exe.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            f'dart compile exe tool/batch.dart -o "{exe}"', cwd=REPO_ROOT / "app", check=True, shell=True
        )
    return exe


Job = tuple[str, int, list[list[dict[str, Any]]], dict[str, Any], int, list[str], str]


def _render_shard(job: Job) -> int:
    split, shard, groups, cfg, start, labels, work = job
    out = Path(work) / f"{split}_{shard:04d}"
    out.mkdir(parents=True, exist_ok=True)
    n = 0
    for k, group in enumerate(groups):
        idx = start + k
        rng = np.random.default_rng([cfg["seed"], SPLITS.index(split), idx + 1, PHOTO_SEED])
        c = copy.deepcopy(cfg)
        multi = len(group) > 1
        c["canvas"]["drawn_frame_prob"] = 1.0 if multi else cfg["photo"]["single_frame_drawn_prob"]
        sample = make_sample(rng, c, [r["spec"] for r in group], labels)
        if sample is None or not sample.ink["strokes"]:
            continue
        img, m, pen, params = render(rng, sample, cfg["photo"])
        sid = f"{split}-{idx:06d}"
        write_pgm(out / f"{sid}.pgm", img)
        meta = {"sample": sample, "m": m, "pen": pen, "params": params, "app": group[0]["app"],
                "uis": [r["ui"] for r in group], "size": (img.shape[1], img.shape[0])}  # fmt: skip
        with open(out / f"{sid}.pkl", "wb") as f:
            pickle.dump(meta, f)
        n += 1
    return n


def _label_shard(args: tuple[str, int, str, bool]) -> dict[str, Any]:
    split, shard, work, keep_eval = args
    src = Path(work) / f"{split}_{shard:04d}"
    vec = Path(work) / f"{split}_{shard:04d}_vec"
    timings = json.loads((vec / "_timings.json").read_text(encoding="utf-8"))["files"]
    path = root() / split / f"shard_{shard:04d}.jsonl.gz"
    path.parent.mkdir(parents=True, exist_ok=True)
    stats: Counter[str] = Counter()
    strokes, noise, lost, micros = [], [], [], []
    with gzip.open(path, "wt", encoding="utf-8") as f:
        for pkl in sorted(src.glob("*.pkl")):
            sid = pkl.stem
            v = vec / f"{sid}.json"
            if not v.exists():
                stats["vectorize_failed"] += 1
                continue
            with open(pkl, "rb") as fh:
                meta = pickle.load(fh)
            out = json.loads(v.read_text(encoding="utf-8"))
            labs = label_map(meta["sample"], meta["m"], meta["pen"], meta["size"])
            rec = label(meta["sample"], meta["m"], out["ink"], labs)
            if rec is None:
                stats["empty"] += 1
                continue
            rec = {
                "id": sid,
                "app": meta["app"],
                "uis": meta["uis"],
                **rec,
                "photo": {
                    **meta["params"],
                    "page": out["page"],
                    "stroke_width": round(out["stroke_width"], 2),
                },
            }
            f.write(json.dumps(rec, ensure_ascii=False, separators=(",", ":")) + "\n")
            stats["ok"] += 1
            strokes.append(len(rec["stroke_cls"]))
            noise.append(sum(1 for g in rec["stroke_group"] if rec["groups"][g]["kind"] == "noise"))
            els = rec["elements"]["elements"]
            lost.append(sum(1 for e in els if not e["strokes"]) / max(1, len(els)))
            micros.append(timings.get(f"{sid}.json", 0))
            if keep_eval:
                base = root() / "eval" / split
                for d in ("ink", "gold", "photo"):
                    (base / d).mkdir(parents=True, exist_ok=True)
                (base / "ink" / f"{sid}.json").write_text(json.dumps(rec["ink"]), encoding="utf-8")
                gold = {k: rec[k] for k in ("id", "stroke_cls", "stroke_group", "groups", "elements", "spec")}
                (base / "gold" / f"{sid}.json").write_text(
                    json.dumps(gold, ensure_ascii=False), encoding="utf-8"
                )
                Image.open(src / f"{sid}.pgm").save(base / "photo" / f"{sid}.png", optimize=True)
    shutil.rmtree(src)
    shutil.rmtree(vec)
    return {"split": split, "stats": dict(stats), "strokes": strokes, "noise": noise, "lost": lost,
            "micros": micros}  # fmt: skip


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=0, help="samples per split (0 = config); for smoke tests")
    ap.add_argument("--workers", type=int, default=8)
    args = ap.parse_args()
    cfg = yaml.safe_load(CONFIG.read_text(encoding="utf-8"))
    records = [
        json.loads(line) for line in (data_root() / "rico_specs" / "specs.jsonl").open(encoding="utf-8")
    ]
    by_split: dict[str, list[dict[str, Any]]] = {s: [] for s in SPLITS}
    for r in records:
        by_split[split_of(r["app"], cfg["dataset"]["split_percent"])].append(r)
    labels = label_pool([r["spec"] for r in records])
    exe = vectorizer_exe()
    work = data_root() / "tmp_photo"
    shutil.rmtree(work, ignore_errors=True)
    size = cfg["dataset"]["shard_size"]

    jobs: list[Job] = []
    for split in SPLITS:
        recs = by_split[split]
        groups = [[recs[i] for i in g] for g in plan(recs, cfg, split)]
        groups = groups[: args.limit or cfg["photo"]["samples"][split]]
        for shard, start in enumerate(range(0, len(groups), size)):
            jobs.append((split, shard, groups[start : start + size], cfg, start, labels, str(work)))

    summary: dict[str, dict[str, Any]] = {s: {} for s in SPLITS}
    acc: dict[str, dict[str, list[float]]] = {
        s: {"strokes": [], "noise": [], "lost": [], "micros": []} for s in SPLITS
    }
    with ProcessPoolExecutor(max_workers=args.workers) as pool:
        for i in range(0, len(jobs), args.workers):
            chunk = jobs[i : i + args.workers]
            list(pool.map(_render_shard, chunk))
            procs = [
                subprocess.Popen(
                    [
                        str(exe),
                        "vectorize",
                        str(work / f"{j[0]}_{j[1]:04d}"),
                        str(work / f"{j[0]}_{j[1]:04d}_vec"),
                    ],
                    stdout=subprocess.DEVNULL,
                )
                for j in chunk
            ]
            for p in procs:
                p.wait()
            for res in pool.map(_label_shard, [(j[0], j[1], str(work), j[0] != "train") for j in chunk]):
                s = res["split"]
                for k, v in res["stats"].items():
                    summary[s][k] = summary[s].get(k, 0) + v
                for k in acc[s]:
                    acc[s][k] += res[k]
            print({s: summary[s].get("ok", 0) for s in SPLITS}, flush=True)

    for s in SPLITS:
        a = acc[s]
        if a["strokes"]:
            summary[s]["pseudo_strokes_per_sample"] = {
                "median": float(np.median(a["strokes"])),
                "p90": float(np.percentile(a["strokes"], 90)),
            }
            summary[s]["noise_strokes_share"] = float(np.sum(a["noise"]) / max(1, np.sum(a["strokes"])))
            summary[s]["elements_without_strokes"] = float(np.mean(a["lost"]))
            summary[s]["vectorize_ms_median"] = float(np.median(a["micros"])) / 1000
    summary["vectorizer"] = {"exe": "tool/batch.dart (dart compile exe)", "workers": args.workers,
                             "cpu_count": os.cpu_count()}  # fmt: skip
    root().mkdir(parents=True, exist_ok=True)
    (root() / "stats.json").write_text(json.dumps(summary, indent=1), encoding="utf-8")
    print(json.dumps(summary, indent=1))


if __name__ == "__main__":
    main()
