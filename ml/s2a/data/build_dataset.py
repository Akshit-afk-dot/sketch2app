"""Build the synthetic sketch dataset from converted RICO specs.

Splits are by app (hash of the package name), so no app's screens appear in two splits: a model that
memorised one app's layout cannot score on that app's other screens. Every sample has its own seed
(seed, split, index), so output does not depend on worker scheduling and any sample can be regenerated.

    python -m s2a.data.build_dataset [--limit N] [--workers 8]
Output under $S2A_DATA_ROOT/synth/v1/:
    {train,val,test}/shard_XXXX.jsonl.gz   samples (ink, per-stroke labels, gold elements, gold spec)
    eval/{val,test}/ink/<id>.json          ink.v1 files for the Dart baselines (tool/batch.dart)
    eval/{val,test}/gold/<id>.json         gold elements + spec for metrics
    stats.json
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
from collections import Counter, defaultdict
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
from typing import Any

import numpy as np
import yaml

from s2a.data.synth import make_sample
from s2a.paths import REPO_ROOT, data_root

SPLITS = ("train", "val", "test")
CONFIG = REPO_ROOT / "ml" / "configs" / "data.yaml"


def out_root() -> Path:
    return data_root() / "synth" / "v1"


def split_of(app: str, percent: dict[str, int]) -> str:
    """Stable split from the app package name (sha1, not Python's salted hash)."""
    bucket = int(hashlib.sha1(app.encode("utf-8")).hexdigest()[:8], 16) % 100
    if bucket < percent["train"]:
        return "train"
    return "val" if bucket < percent["train"] + percent["val"] else "test"


def plan(records: list[dict[str, Any]], cfg: dict[str, Any], split: str) -> list[list[int]]:
    """Which spec indices go into each sample: each spec once, some joined with screens of the same app."""
    rng = np.random.default_rng([cfg["seed"], SPLITS.index(split), 0])
    by_app: dict[str, list[int]] = defaultdict(list)
    for i, r in enumerate(records):
        by_app[r["app"]].append(i)
    out = []
    for i, r in enumerate(records):
        group = [i]
        if rng.random() < cfg["multiscreen"]["share"]:
            same = [j for j in by_app[r["app"]] if j != i]
            pool = same if same else list(range(len(records)))
            extra = int(rng.integers(1, cfg["multiscreen"]["max_screens"]))
            group += [int(j) for j in rng.choice(pool, size=min(extra, len(pool)), replace=False)]
        out.append(group)
    return out


Job = tuple[str, int, list[list[dict[str, Any]]], dict[str, Any], int]


def _build_shard(job: Job) -> dict[str, Any]:
    """One shard; each group is the list of source records (spec + metadata) for one sample."""
    split, shard, groups, cfg, start = job
    path = out_root() / split / f"shard_{shard:04d}.jsonl.gz"
    path.parent.mkdir(parents=True, exist_ok=True)
    stats: Counter[str] = Counter()
    types: Counter[str] = Counter()
    strokes: list[int] = []
    with gzip.open(path, "wt", encoding="utf-8") as f:
        for k, group in enumerate(groups):
            idx = start + k
            rng = np.random.default_rng([cfg["seed"], SPLITS.index(split), idx + 1])
            sample = make_sample(rng, cfg, [r["spec"] for r in group])
            if sample is None:
                stats["failed"] += 1
                continue
            stats["ok"] += 1
            stats[f"screens_{len(group)}"] += 1
            types.update(e["type"] for e in sample.elements["elements"])
            strokes.append(len(sample.stroke_cls))
            rec = {
                "id": f"{split}-{idx:06d}",
                "app": group[0]["app"],
                "uis": [r["ui"] for r in group],
                "ink": sample.ink,
                "stroke_cls": sample.stroke_cls,
                "stroke_group": sample.stroke_group,
                "groups": sample.groups,
                "elements": sample.elements,
                "spec": sample.spec,
            }
            f.write(json.dumps(rec, ensure_ascii=False, separators=(",", ":")) + "\n")
    return {"split": split, "stats": dict(stats), "types": dict(types), "strokes": strokes}


def export_eval(split: str, limit: int) -> int:
    """First [limit] samples of a split as individual files for the Dart baselines and metrics."""
    base = out_root() / "eval" / split
    (base / "ink").mkdir(parents=True, exist_ok=True)
    (base / "gold").mkdir(parents=True, exist_ok=True)
    n = 0
    for shard in sorted((out_root() / split).glob("shard_*.jsonl.gz")):
        with gzip.open(shard, "rt", encoding="utf-8") as f:
            for line in f:
                rec = json.loads(line)
                (base / "ink" / f"{rec['id']}.json").write_text(json.dumps(rec["ink"]), encoding="utf-8")
                gold = {k: rec[k] for k in ("id", "stroke_cls", "stroke_group", "groups", "elements", "spec")}
                (base / "gold" / f"{rec['id']}.json").write_text(
                    json.dumps(gold, ensure_ascii=False), encoding="utf-8"
                )
                n += 1
                if n >= limit:
                    return n
    return n


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=0, help="specs per split (0 = all); for smoke tests")
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--config", type=Path, default=CONFIG)
    args = ap.parse_args()
    cfg = yaml.safe_load(args.config.read_text(encoding="utf-8"))

    records = [
        json.loads(line) for line in (data_root() / "rico_specs" / "specs.jsonl").open(encoding="utf-8")
    ]
    by_split: dict[str, list[dict[str, Any]]] = {s: [] for s in SPLITS}
    for r in records:
        by_split[split_of(r["app"], cfg["dataset"]["split_percent"])].append(r)

    jobs: list[Job] = []
    size = cfg["dataset"]["shard_size"]
    for split in SPLITS:
        recs = by_split[split][: args.limit] if args.limit else by_split[split]
        groups = [[recs[i] for i in g] for g in plan(recs, cfg, split)]
        for shard, start in enumerate(range(0, len(groups), size)):
            jobs.append((split, shard, groups[start : start + size], cfg, start))

    summary: dict[str, Any] = {
        s: {"specs": len(by_split[s]), "apps": len({r["app"] for r in by_split[s]})} for s in SPLITS
    }
    type_counts: dict[str, Counter[str]] = {s: Counter() for s in SPLITS}
    stroke_counts: dict[str, list[int]] = {s: [] for s in SPLITS}
    with ProcessPoolExecutor(max_workers=args.workers) as pool:
        for res in pool.map(_build_shard, jobs):
            s = res["split"]
            for k, v in res["stats"].items():
                summary[s][k] = summary[s].get(k, 0) + v
            type_counts[s].update(res["types"])
            stroke_counts[s].extend(res["strokes"])
            print(f"{s}: {summary[s].get('ok', 0)} samples", flush=True)

    for s in SPLITS:
        sc = stroke_counts[s]
        summary[s]["element_types"] = dict(type_counts[s].most_common())
        if sc:
            summary[s]["strokes_per_sample"] = {
                "median": float(np.median(sc)),
                "p90": float(np.percentile(sc, 90)),
                "max": int(max(sc)),
            }
    for s in ("val", "test"):
        summary[s]["eval_exported"] = export_eval(s, cfg["dataset"]["eval_export"])
    (out_root() / "stats.json").write_text(json.dumps(summary, indent=1), encoding="utf-8")
    print(
        json.dumps(
            {s: {k: v for k, v in summary[s].items() if k != "element_types"} for s in SPLITS}, indent=1
        )
    )


if __name__ == "__main__":
    main()
