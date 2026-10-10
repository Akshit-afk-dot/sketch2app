"""Build the Collect-mode task set (app/assets/collect/tasks.json).

Targets come from the hand-written examples and from RICO apps in the TEST split, so no collected sketch
depicts a layout the models were trained on. Each target is normalised to what the sketch legend can
express (generic icons, short labels, small lists), so the gold spec is exactly what a person can draw.

    python -m s2a.data.collect_set [--rico 30]
"""

from __future__ import annotations

import argparse
import copy
import json
from typing import Any

import numpy as np
import yaml

from s2a.data.build_dataset import CONFIG, split_of
from s2a.data.rico_convert import count_elements
from s2a.paths import REPO_ROOT, SPEC_DIR, data_root
from s2a.spec import canonicalize, validate
from s2a.spec.naming import screen_names, screen_title

OUT = REPO_ROOT / "app" / "assets" / "collect" / "tasks.json"
Node = dict[str, Any]


def _short(s: str, words: int = 3, chars: int = 20) -> str:
    out = " ".join(s.split()[:words])
    return out[:chars].rstrip()


def sketchable(n: Any) -> Any:
    """Normalise a spec subtree: generic icons, short labels, lists of at most 6."""
    if isinstance(n, list):
        return [sketchable(x) for x in n]
    if not isinstance(n, dict):
        return n
    out = {k: sketchable(v) for k, v in n.items()}
    t = out.get("t")
    if t == "icon":
        out["name"] = "menu" if out["name"] == "menu" else "circle"
    if t == "fab":
        out["icon"] = "add"
    if t in ("list", "grid"):
        out["n"] = min(out["n"], 6)
    for key in ("label", "v", "title"):
        if isinstance(out.get(key), str):
            out[key] = _short(out[key])
    if "options" in out:
        out["options"] = [_short(o, 2, 14) for o in out["options"]][:4]
    if "items" in out and t == "bottomnav":
        out["items"] = [{**i, "icon": "circle", "label": _short(i["label"], 1, 10)} for i in out["items"]][:4]
    return out


def _types(n: Any, acc: set[str]) -> None:
    if isinstance(n, dict):
        if "t" in n:
            acc.add(n["t"])
        for v in n.values():
            _types(v, acc)
    elif isinstance(n, list):
        for v in n:
            _types(v, acc)


def _finish(spec: Node) -> Node | None:
    """Apply the shared naming rule, canonicalise, validate."""
    screens = spec["screens"]
    for s, (sid, title) in zip(screens, screen_names([screen_title(s) for s in screens]), strict=True):
        s["id"], s["title"] = sid, title
    spec = canonicalize(spec)
    return spec if not validate(spec) else None


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--rico", type=int, default=30, help="RICO test-split targets to include")
    args = ap.parse_args()
    cfg = yaml.safe_load(CONFIG.read_text(encoding="utf-8"))
    rng = np.random.default_rng(cfg["seed"])
    tasks: list[dict[str, Any]] = []
    for p in sorted((SPEC_DIR / "examples").glob("*.json")):
        spec = json.loads(p.read_text(encoding="utf-8"))
        # Keep example ids/links as written: they are already sketch-friendly.
        norm = canonicalize(sketchable(spec))
        if not validate(norm):
            tasks.append({"id": f"ex_{p.stem}", "source": "example", "spec": norm})

    recs = [json.loads(line) for line in (data_root() / "rico_specs" / "specs.jsonl").open(encoding="utf-8")]
    test = [r for r in recs if split_of(r["app"], cfg["dataset"]["split_percent"]) == "test"]
    rng.shuffle(test)
    covered: dict[str, int] = {}
    picked = 0
    for r in test:
        if picked >= args.rico:
            break
        spec = sketchable(copy.deepcopy(r["spec"]))
        body_leaves = count_elements(spec["screens"][0]["body"])
        if not 4 <= body_leaves <= 10:
            continue
        kinds: set[str] = set()
        _types(spec, kinds)
        # Greedy diversity: prefer targets with element types we have few of so far.
        novelty = sum(1 for k in kinds if covered.get(k, 0) < 4)
        if novelty == 0 and rng.random() < 0.7:
            continue
        done = _finish(spec)
        if done is None:
            continue
        for k in kinds:
            covered[k] = covered.get(k, 0) + 1
        tasks.append({"id": f"rico_{r['ui']}", "source": f"rico:{r['app']}", "spec": done})
        picked += 1

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps({"v": 1, "tasks": tasks}, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"{len(tasks)} tasks -> {OUT}; element types covered: {dict(sorted(covered.items()))}")


if __name__ == "__main__":
    main()
