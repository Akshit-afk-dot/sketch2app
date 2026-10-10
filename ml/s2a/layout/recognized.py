"""Run the trained recognizer on eval sketches to get realistic layout inputs.

    python -m s2a.layout.recognized --split val     # then: python -m s2a.layout.noise measure
    python -m s2a.layout.recognized --split test
    python -m s2a.layout.recognized --data real --split train   # Collect-mode sketches (and --split test)

Writes eval/<split>/recognized/<id>.json (raw predicted element lists, for measuring error rates) and
eval/<split>/recognized.jsonl (the same, with each matched element's gold label attached, i.e. a
perfect handwriting reader; the layout evaluation's "recognizer" input condition).
Uses app/assets/models/recognizer.onnx, the model that ships in the app.
"""

from __future__ import annotations

import argparse
import json

import onnxruntime as ort

from s2a.data.collected import eval_root
from s2a.paths import REPO_ROOT
from s2a.recognizer.decode import decode
from s2a.recognizer.features import ink_features
from s2a.recognizer.metrics import match


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", choices=["synth", "real"], default="synth")
    ap.add_argument("--split", choices=["train", "val", "test"], default="val")
    args = ap.parse_args()
    sess = ort.InferenceSession(
        str(REPO_ROOT / "app" / "assets" / "models" / "recognizer.onnx"), providers=["CPUExecutionProvider"]
    )
    base = eval_root(args.data) / args.split
    raw_dir = base / "recognized"
    raw_dir.mkdir(exist_ok=True)
    n = 0
    with (base / "recognized.jsonl").open("w", encoding="utf-8") as out:
        for ink_path in sorted((base / "ink").glob("*.json")):
            ink = json.loads(ink_path.read_text(encoding="utf-8"))
            gold = json.loads((base / "gold" / ink_path.name).read_text(encoding="utf-8"))["elements"]
            if not ink["strokes"]:
                continue
            shape, geom = ink_features(ink)
            c, t, a = (o[0] for o in sess.run(None, {"shape": shape[None], "geom": geom[None]}))
            pred = decode(ink, c, t, a)
            (raw_dir / ink_path.name).write_text(json.dumps(pred), encoding="utf-8")
            for i, j in match(pred["elements"], gold["elements"]):
                if gold["elements"][j].get("text"):
                    pred["elements"][i]["text"] = gold["elements"][j]["text"]
            out.write(json.dumps({"id": ink_path.stem, "elements": pred}) + "\n")
            n += 1
    print(f"{n} sketches -> {base / 'recognized.jsonl'}")


if __name__ == "__main__":
    main()
