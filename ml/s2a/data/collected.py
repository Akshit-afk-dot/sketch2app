"""Import real sketches from Collect mode (the zip the app exports) and split them by participant.

    python -m s2a.data.collected import <export.zip or folder>   # validate + store, update splits
    python -m s2a.data.collected stats

Real data is split by PARTICIPANT, not by sketch: one person's drawing style must not appear in both the
fine-tuning set and the held-out test set. The assignment is frozen in splits.json the first time a
participant is seen (hash-based, ~40% held out), so later imports never move anyone into training.
Both splits are also exported in the synthetic eval format (eval/<split>/{ink,gold}): `test` is the
held-out real test set; `train` is where the recognizer's real-sketch error rates are measured
(s2a.layout.noise) and real-data fine-tuning is checked.
"""

from __future__ import annotations

import hashlib
import json
import sys
import zipfile
from collections import Counter
from pathlib import Path
from typing import Any

from s2a.data.build_dataset import out_root
from s2a.paths import data_root
from s2a.spec import validate

TEST_PERCENT = 40
KEYS = ("id", "participant", "task", "ink", "stroke_cls", "stroke_group", "groups", "elements", "spec")


def real_root() -> Path:
    return data_root() / "real" / "v1"


def eval_root(data: str) -> Path:
    """Eval-format sketches (<split>/{ink,gold}): synthetic (`synth`) or from Collect mode (`real`)."""
    return real_root() / "eval" if data == "real" else out_root() / "eval"


def check_record(rec: dict[str, Any]) -> list[str]:
    """Problems that would make a record unusable for training or evaluation."""
    problems = [f"missing {k}" for k in KEYS if k not in rec]
    if problems:
        return problems
    n = len(rec["ink"]["strokes"])
    if n == 0:
        problems.append("no strokes")
    if len(rec["stroke_cls"]) != n or len(rec["stroke_group"]) != n:
        problems.append("label length mismatch")
    if any(g < 0 or g >= len(rec["groups"]) for g in rec["stroke_group"]):
        problems.append("stroke without a group")
    if validate(rec["spec"]):
        problems.append("invalid gold spec")
    return problems


def _split_for(participant: str, splits: dict[str, str]) -> str:
    if participant not in splits:
        bucket = int(hashlib.sha1(participant.encode()).hexdigest()[:8], 16) % 100
        splits[participant] = "test" if bucket < TEST_PERCENT else "train"
    return splits[participant]


def _records(src: Path) -> list[dict[str, Any]]:
    if src.suffix == ".zip":
        with zipfile.ZipFile(src) as z:
            return [json.loads(z.read(n)) for n in z.namelist() if n.endswith(".json")]
    return [json.loads(p.read_text(encoding="utf-8")) for p in src.rglob("*.json")]


def import_records(src: Path) -> dict[str, Any]:
    root = real_root()
    split_file = root / "splits.json"
    splits: dict[str, str] = json.loads(split_file.read_text(encoding="utf-8")) if split_file.exists() else {}
    report: Counter[str] = Counter()
    for rec in _records(src):
        problems = check_record(rec)
        if problems:
            report["rejected"] += 1
            print(f"rejected {rec.get('id')}: {', '.join(problems)}")
            continue
        split = _split_for(rec["participant"], splits)
        out = root / split / "records" / f"{rec['id']}.json"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(rec, ensure_ascii=False), encoding="utf-8")
        report[split] += 1
        base = root / "eval" / split
        (base / "ink").mkdir(parents=True, exist_ok=True)
        (base / "gold").mkdir(parents=True, exist_ok=True)
        (base / "ink" / f"{rec['id']}.json").write_text(json.dumps(rec["ink"]), encoding="utf-8")
        gold = {k: rec[k] for k in ("id", "stroke_cls", "stroke_group", "groups", "elements", "spec")}
        (base / "gold" / f"{rec['id']}.json").write_text(
            json.dumps(gold, ensure_ascii=False), encoding="utf-8"
        )
    split_file.parent.mkdir(parents=True, exist_ok=True)
    split_file.write_text(json.dumps(splits, indent=1, sort_keys=True), encoding="utf-8")
    return dict(report)


def stats() -> dict[str, Any]:
    root = real_root()
    splits = (
        json.loads((root / "splits.json").read_text(encoding="utf-8"))
        if (root / "splits.json").exists()
        else {}
    )
    out: dict[str, Any] = {"participants": Counter(splits.values())}
    for split in ("train", "test"):
        out[f"{split}_sketches"] = len(list((root / split / "records").glob("*.json")))
    return out


def main() -> None:
    if len(sys.argv) >= 3 and sys.argv[1] == "import":
        print(json.dumps(import_records(Path(sys.argv[2])), indent=1))
    print(json.dumps(stats(), indent=1, default=dict))


if __name__ == "__main__":
    main()
