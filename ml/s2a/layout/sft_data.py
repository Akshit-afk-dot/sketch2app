"""Build layout-model SFT data and evaluation prompts; package them for the Colab/Kaggle notebook.

    python -m s2a.layout.sft_data

Writes $S2A_DATA_ROOT/llm/{sft_train,sft_val}.jsonl, eval_test_*.jsonl and sketch2app_llm_bundle.zip
(the data plus the metric code the notebook needs).

Each example: prompt = element list text (prompt.py) of a noisy copy of the gold element list (noise.py,
rates measured from the real recognizer); completion = canonical gold spec. 20% of training inputs stay
clean so the model also learns the noise-free mapping; noise strength otherwise varies 0.5-1.5x.
Examples longer than the context budget are dropped and counted.
"""

from __future__ import annotations

import gzip
import json
import zipfile
from pathlib import Path
from typing import Any

import numpy as np

from s2a.data.build_dataset import out_root
from s2a.layout.noise import NOISE_STATS, corrupt
from s2a.layout.prompt import INSTRUCTION, build_prompt
from s2a.paths import REPO_ROOT, data_root
from s2a.spec import canonical_json
from s2a.spec.tokens import load_tokenizers

MAX_TOKENS = 2048
VAL_EXAMPLES = 500
SEED = 1234


def llm_dir() -> Path:
    d = data_root() / "llm"
    d.mkdir(parents=True, exist_ok=True)
    return d


def _records(split: str) -> list[dict[str, Any]]:
    out = []
    for shard in sorted((out_root() / split).glob("shard_*.jsonl.gz")):
        with gzip.open(shard, "rt", encoding="utf-8") as f:
            for line in f:
                r = json.loads(line)
                out.append({"id": r["id"], "elements": r["elements"], "spec": r["spec"]})
    return out


def build(split: str, stats: dict[str, Any], limit: int = 0) -> tuple[list[dict[str, str]], dict[str, int]]:
    rng = np.random.default_rng([SEED, ("train", "val", "test").index(split)])
    tok = load_tokenizers()["gemma-4-E2B-it"]
    rows, counts = [], {"too_long": 0, "clean": 0, "noisy": 0}
    for r in _records(split)[: limit or None]:
        clean = split == "train" and rng.random() < 0.2
        strength = 0.0 if clean else (float(rng.uniform(0.5, 1.5)) if split == "train" else 1.0)
        prompt = build_prompt(corrupt(r["elements"], stats, rng, strength))
        completion = canonical_json(r["spec"])
        n = len(tok.encode(prompt).ids) + len(tok.encode(completion).ids)
        if n > MAX_TOKENS - 32:  # room for the chat template
            counts["too_long"] += 1
            continue
        counts["clean" if clean else "noisy"] += 1
        rows.append({"id": r["id"], "prompt": prompt, "completion": completion})
    return rows, counts


def eval_prompts(split: str) -> dict[str, list[dict[str, Any]]]:
    """Prompts for the two evaluation conditions: gold element lists and real recognizer output."""
    base = out_root() / "eval" / split
    gold = {p.stem: json.loads(p.read_text(encoding="utf-8")) for p in sorted((base / "gold").glob("*.json"))}
    out = {"gold": [{"id": k, "prompt": build_prompt(g["elements"])} for k, g in gold.items()]}
    rec = base / "recognized.jsonl"
    if rec.exists():
        out["recognizer"] = [
            {"id": r["id"], "prompt": build_prompt(r["elements"])}
            for r in map(json.loads, rec.open(encoding="utf-8"))
        ]
    for rows in out.values():
        for row in rows:
            row["gold"] = gold[row["id"]]["spec"]
    return out


def bundle(files: list[Path]) -> Path:
    """Data + the code the notebook needs to score outputs (spec validator, metrics, prompt format)."""
    path = llm_dir() / "sketch2app_llm_bundle.zip"
    modules = ["__init__", "paths", "layout/__init__", "layout/metrics", "layout/prompt"]
    modules += [f"spec/{m}" for m in ("__init__", "canonical", "validate", "vocab", "naming")]
    code = [f"ml/s2a/{m}.py" for m in modules] + ["spec/schema/ui_spec.v1.schema.json"]
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for rel in code:
            z.write(REPO_ROOT / rel, rel)
        for f in files:
            z.write(f, f"data/{f.name}")
    return path


def main() -> None:
    stats = json.loads(NOISE_STATS.read_text(encoding="utf-8"))
    files = []
    report: dict[str, Any] = {"instruction": INSTRUCTION}
    for split, name in (("train", "sft_train"), ("val", "sft_val")):
        rows, counts = build(split, stats, limit=VAL_EXAMPLES if split == "val" else 0)
        path = llm_dir() / f"{name}.jsonl"
        path.write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n", encoding="utf-8")
        files.append(path)
        report[name] = {"examples": len(rows), **counts}
    for cond, rows in eval_prompts("test").items():
        path = llm_dir() / f"eval_test_{cond}.jsonl"
        path.write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n", encoding="utf-8")
        files.append(path)
        report[f"eval_test_{cond}"] = len(rows)
    report["bundle"] = str(bundle(files))
    (llm_dir() / "sft_report.json").write_text(json.dumps(report, indent=1), encoding="utf-8")
    print(json.dumps(report, indent=1))


if __name__ == "__main__":
    main()
