"""Measure how many LLM tokens a spec costs, per screen, with the real tokenizers of both target models.

Why: on-device decode speed is roughly linear in output tokens, so the spec format must stay small
(target: median < ~250 tokens per screen). Writes docs/results/spec_tokens.json for docs/results.md.

    python -m s2a.spec.tokens [--extra-dart DIR]
"""

import argparse
import json
import os
import statistics
from pathlib import Path
from typing import Any

from tokenizers import Tokenizer

from s2a.paths import REPO_ROOT, SPEC_DIR, data_root
from s2a.spec.canonical import canonical_json, canonicalize

TOKENIZERS = {"gemma-4-E2B-it": "google/gemma-4-E2B-it", "qwen3.5-0.8B": "Qwen/Qwen3.5-0.8B"}
OUT = REPO_ROOT / "docs" / "results" / "spec_tokens.json"


def load_tokenizers() -> dict[str, Tokenizer]:
    os.environ.setdefault("HF_HOME", str(data_root() / "hf"))
    return {name: Tokenizer.from_pretrained(repo) for name, repo in TOKENIZERS.items()}


def count(tok: Tokenizer, text: str) -> int:
    return len(tok.encode(text, add_special_tokens=False).ids)


def per_screen_texts(spec: dict[str, Any]) -> list[str]:
    """Each screen as its own one-screen canonical spec, so screens are comparable across apps."""
    canon = canonicalize(spec)
    return [canonical_json({"v": 1, "screens": [s]}) for s in canon["screens"]]


def summarize(values: list[int]) -> dict[str, float]:
    return {"n": len(values), "median": statistics.median(values), "mean": statistics.fmean(values),
            "max": max(values), "min": min(values)}  # fmt: skip


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--extra-dart",
        type=Path,
        help="dir of exported projects; counts screens + main.dart (not the shared widgets)",
    )
    args = parser.parse_args()
    toks = load_tokenizers()
    rows = []
    for path in sorted((SPEC_DIR / "examples").glob("*.json")):
        spec = json.loads(path.read_text(encoding="utf-8"))
        row: dict[str, Any] = {"example": path.stem, "screens": len(spec["screens"])}
        pretty = json.dumps(spec, indent=2, ensure_ascii=False)
        for name, tok in toks.items():
            row[f"{name}/canonical"] = count(tok, canonical_json(spec))
            row[f"{name}/pretty"] = count(tok, pretty)
            row[f"{name}/per_screen"] = [count(tok, t) for t in per_screen_texts(spec)]
            if args.extra_dart:
                dart = "".join(
                    p.read_text(encoding="utf-8")
                    for p in sorted((args.extra_dart / path.stem / "lib").rglob("*.dart"))
                    if p.name != "sketch_widgets.dart"  # shared library: written once, not generated per app
                )
                row[f"{name}/dart"] = count(tok, dart)
        rows.append(row)

    summary: dict[str, dict[str, Any]] = {}
    for name in toks:
        screens = [n for r in rows for n in r[f"{name}/per_screen"]]
        summary[name] = {"per_screen_canonical": summarize(screens)}
        summary[name]["pretty_over_canonical"] = statistics.fmean(
            r[f"{name}/pretty"] / r[f"{name}/canonical"] for r in rows
        )
        if args.extra_dart:
            summary[name]["dart_over_canonical"] = statistics.fmean(
                r[f"{name}/dart"] / r[f"{name}/canonical"] for r in rows
            )
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(
        json.dumps({"source": "spec/examples", "rows": rows, "summary": summary}, indent=1), encoding="utf-8"
    )
    print(json.dumps(summary, indent=1))


if __name__ == "__main__":
    main()
