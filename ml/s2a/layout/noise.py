"""Realistic input noise for layout-model training, with rates measured from the real recognizer.

The layout model is trained on element lists derived from gold specs. If those inputs were perfect, it
would never learn to recover from what the recognizer and handwriting reader actually get wrong. So we
measure the trained recognizer on the val split (python -m s2a.layout.noise measure) and replay those
error rates on gold element lists. Synthetic val understates real-sketch errors, so once Collect-mode
data exists, measure on its fine-tuning split instead (--data real --split train) and rebuild the SFT
data with `sft_data --noise` pointing at that file:
    - misses: drop an element with its type's measured miss rate
    - confusions: change a type with the measured P(pred type | gold type)
    - false positives: add spurious elements at the measured rate, with the measured type mix
    - box jitter: gaussian noise with the measured std of matched-box offsets
    - handwriting: character errors at CER (default 8%, to be re-measured from real ML Kit readings in
      Collect mode) and a chance the label is missing altogether
"""

from __future__ import annotations

import argparse
import copy
import json
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

import numpy as np

from s2a.data.collected import eval_root
from s2a.paths import REPO_ROOT
from s2a.recognizer.metrics import match

NOISE_STATS = REPO_ROOT / "docs" / "results" / "recognizer_noise_val.json"
DEFAULT_TEXT = {"cer": 0.08, "missing_text": 0.05}
ALPHABET = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 "


def measure(pred_dir: Path, gold_dir: Path) -> dict[str, Any]:
    """Error statistics of predicted element lists against gold ones (same file names)."""
    gold_n: Counter[str] = Counter()
    matched: dict[str, Counter[str]] = defaultdict(Counter)
    fp: Counter[str] = Counter()
    offsets: list[float] = []
    sketches = 0
    for g in sorted(gold_dir.glob("*.json")):
        p = pred_dir / g.name
        if not p.exists():
            continue
        sketches += 1
        gold = json.loads(g.read_text(encoding="utf-8"))["elements"]
        pred = json.loads(p.read_text(encoding="utf-8"))
        ge, pe = gold["elements"], pred["elements"]
        gold_n.update(e["type"] for e in ge)
        pairs = match(pe, ge)
        hit_p = {i for i, _ in pairs}
        frame_w = {f["id"]: f["box"][2] for f in gold["frames"]}
        for i, j in pairs:
            matched[ge[j]["type"]][pe[i]["type"]] += 1
            w = frame_w.get(ge[j].get("frame", 0), 360.0)
            offsets += [(pe[i]["box"][k] - ge[j]["box"][k]) / w for k in range(4)]
        fp.update(e["type"] for i, e in enumerate(pe) if i not in hit_p)
    miss = {t: 1 - sum(matched[t].values()) / n for t, n in gold_n.items()}
    confusion = {t: {p: c / sum(row.values()) for p, c in row.items()} for t, row in matched.items()}
    return {
        "sketches": sketches,
        "miss_rate": miss,
        "confusion": confusion,
        "false_positives_per_sketch": sum(fp.values()) / max(sketches, 1),
        "false_positive_types": {t: c / max(sum(fp.values()), 1) for t, c in fp.items()},
        "box_offset_std": float(np.std(offsets)) if offsets else 0.01,
        **DEFAULT_TEXT,
    }


def _typo(text: str, cer: float, rng: np.random.Generator) -> str:
    out = []
    for ch in text:
        r = rng.random()
        if r < cer / 3:
            continue  # deletion
        if r < 2 * cer / 3:
            out.append(str(rng.choice(list(ALPHABET))))  # substitution
        elif r < cer:
            out += [ch, str(rng.choice(list(ALPHABET)))]  # insertion
        else:
            out.append(ch)
    return "".join(out).strip()


def corrupt(
    el: dict[str, Any], stats: dict[str, Any], rng: np.random.Generator, strength: float = 1.0
) -> dict[str, Any]:
    """A noisy copy of a gold element list. strength scales every rate (0 = clean)."""
    out = copy.deepcopy(el)
    frames = {f["id"]: f["box"] for f in out["frames"]}
    kept = []
    for e in out["elements"]:
        if rng.random() < strength * stats["miss_rate"].get(e["type"], 0.0):
            continue
        row = stats["confusion"].get(e["type"])
        if row and rng.random() < strength:
            types, probs = zip(*row.items(), strict=True)
            e["type"] = str(rng.choice(types, p=np.array(probs) / sum(probs)))
        w = frames.get(e.get("frame", 0), [0, 0, 360, 720])[2]
        e["box"] = [v + float(rng.normal(0, strength * stats["box_offset_std"] * w)) for v in e["box"]]
        e["box"][2], e["box"][3] = max(1.0, e["box"][2]), max(0.0, e["box"][3])
        if e.get("text"):
            if rng.random() < strength * stats["missing_text"]:
                del e["text"]
            else:
                e["text"] = _typo(e["text"], strength * stats["cer"], rng) or e["text"]
        kept.append(e)
    n_fp = rng.poisson(strength * stats["false_positives_per_sketch"])
    fp_types = stats["false_positive_types"]
    for _ in range(int(n_fp)):
        if not fp_types or not out["frames"]:
            break
        f = out["frames"][int(rng.integers(len(out["frames"])))]
        fx, fy, fw, fh = f["box"]
        t = str(rng.choice(list(fp_types), p=np.array(list(fp_types.values())) / sum(fp_types.values())))
        size = float(rng.uniform(0.04, 0.2))
        box = [
            fx + float(rng.uniform(0, 0.9)) * fw,
            fy + float(rng.uniform(0, 0.95)) * fh,
            size * fw,
            size * fw * 0.4,
        ]
        kept.append({"id": 10_000 + len(kept), "type": t, "box": box, "frame": f["id"]})
    out["elements"] = kept
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("command", choices=["measure"])
    ap.add_argument("--data", choices=["synth", "real"], default="synth")
    ap.add_argument("--split", choices=["train", "val"], default="val")
    args = ap.parse_args()
    base = eval_root(args.data) / args.split  # recognized/ is written by s2a.layout.recognized
    stats = measure(base / "recognized", base / "gold")
    stats["source"] = f"{args.data}/{args.split}"
    out = NOISE_STATS
    if args.data == "real":
        out = NOISE_STATS.with_name(f"recognizer_noise_real_{args.split}.json")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(stats, indent=1), encoding="utf-8")
    print(f"wrote {out}")
    print(json.dumps({k: v for k, v in stats.items() if k not in ("confusion",)}, indent=1))


if __name__ == "__main__":
    main()
