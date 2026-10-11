"""Write docs/data_report.md (+ figures) from the artifacts the pipeline actually produced.

python -m s2a.data.report
"""

from __future__ import annotations

import gzip
import json
import statistics
from collections import Counter
from collections.abc import Sequence
from pathlib import Path
from typing import Any

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import yaml

from s2a.data.build_dataset import CONFIG, SPLITS, out_root
from s2a.data.render import render_ink, save_grid
from s2a.paths import REPO_ROOT, data_root
from s2a.spec import canonical_json
from s2a.spec.tokens import load_tokenizers, per_screen_texts

DOCS = REPO_ROOT / "docs"
FIG = DOCS / "figures"


def _node_types(n: dict[str, Any], c: Counter[str]) -> None:
    c[n["t"]] += 1
    for k in n.get("c", []):
        _node_types(k, c)
    if "item" in n:
        _node_types(n["item"], c)


def _leaves(n: dict[str, Any]) -> int:
    kids = n.get("c") or ([n["item"]] if "item" in n else [])
    return sum(_leaves(k) for k in kids) if kids else 1


def _pct(values: Sequence[float], q: float) -> float:
    return float(np.percentile(values, q)) if values else float("nan")


def _hist(values: Sequence[float], title: str, xlabel: str, path: Path, line: float | None = None) -> None:
    fig, ax = plt.subplots(figsize=(6, 3.2), dpi=120)
    ax.hist(values, bins=40, color="#4f5bd5")
    if line is not None:
        ax.axvline(line, color="#d62728", linestyle="--", label=f"target {line:g}")
        ax.legend()
    ax.set_title(title)
    ax.set_xlabel(xlabel)
    ax.set_ylabel("count")
    fig.tight_layout()
    fig.savefig(path)
    plt.close(fig)


def photo_section(cfg: dict[str, Any]) -> list[str]:
    """Section on the synthetic-photo dataset (s2a.data.build_photo), if it has been built."""
    from PIL import Image, ImageDraw

    from s2a.data.build_photo import root as photo_root

    stats_path = photo_root() / "stats.json"
    if not stats_path.exists():
        return [
            "## 5. Synthetic photos (photo mode)",
            "",
            "Not built yet (`python -m s2a.data.build_photo`).",
            "",
        ]
    st = json.loads(stats_path.read_text(encoding="utf-8"))
    base = photo_root() / "eval" / "val"
    colours = {"frame": (150, 150, 150), "text": (40, 90, 230), "shape": (0, 0, 0), "arrow": (220, 120, 0)}
    tiles = []
    for photo in sorted((base / "photo").glob("*.png"))[:4]:
        gold = json.loads((base / "gold" / f"{photo.stem}.json").read_text(encoding="utf-8"))
        ink = json.loads((base / "ink" / f"{photo.stem}.json").read_text(encoding="utf-8"))
        img = Image.open(photo).convert("RGB")
        over = Image.new("RGB", img.size, "white")
        d = ImageDraw.Draw(over)
        for k, stroke in enumerate(ink["strokes"]):
            noise = gold["groups"][gold["stroke_group"][k]]["kind"] == "noise"
            col = (230, 0, 0) if noise else colours[gold["stroke_cls"][k]]
            pts = [tuple(q[:2]) for q in stroke["pts"]]
            if len(pts) > 1:
                d.line(pts, fill=col, width=2)
            else:
                d.ellipse([pts[0][0] - 2, pts[0][1] - 2, pts[0][0] + 2, pts[0][1] + 2], fill=col)
        tile = Image.new("RGB", (img.width * 2, img.height), "white")
        tile.paste(img, (0, 0))
        tile.paste(over, (img.width, 0))
        tile.thumbnail((1200, 450))
        tiles.append(tile)
    if tiles:
        grid = Image.new("RGB", (max(t.width for t in tiles), sum(t.height for t in tiles)), "white")
        y = 0
        for t in tiles:
            grid.paste(t, (0, y))
            y += t.height
        grid.save(FIG / "photo_samples.png", optimize=True)
    pc = cfg["photo"]
    rows = [
        f"| {s} | {st[s].get('ok', 0):,} | {st[s]['pseudo_strokes_per_sample']['median']:.0f}, "
        f"{st[s]['pseudo_strokes_per_sample']['p90']:.0f} | {st[s]['noise_strokes_share']:.1%} | "
        f"{st[s]['elements_without_strokes']:.1%} | {st[s]['vectorize_ms_median']:.0f} |"
        for s in SPLITS
        if s in st and "pseudo_strokes_per_sample" in st[s]
    ]
    return [
        "## 5. Synthetic photos (photo mode)",
        "",
        "Same specs and by-app splits as above, drawn as phone photos of paper (`ml/s2a/data/photo.py`)",
        "and turned into strokes by the app's own vectorizer (`app/lib/photo/vectorize.dart`, compiled).",
        "Each pseudo-stroke takes the element group under most of its points; strokes mostly over blank",
        "paper are noise.",
        "",
        "| Split | Photos | Pseudo-strokes/photo (median, p90) | Noise strokes "
        "| Elements with no strokes left | Vectorize ms (median) |",
        "|---|---:|---|---:|---:|---:|",
        *rows,
        "",
        "Photo effects (configs/data.yaml `photo`): "
        + ", ".join(f"{k} {v}" for k, v in pc.items() if k not in ("samples", "long_side"))
        + f"; long side {pc['long_side']} px.",
        "",
        "Validation photos (left) and the strokes the vectorizer extracted, coloured by label (frame grey,",
        "text blue, shape black, arrow orange, noise red):",
        "",
        "![photos](figures/photo_samples.png)",
        "",
    ]


def main() -> None:
    FIG.mkdir(parents=True, exist_ok=True)
    cfg = yaml.safe_load(CONFIG.read_text(encoding="utf-8"))
    conv = json.loads((data_root() / "rico_specs" / "stats.json").read_text(encoding="utf-8"))
    synth = json.loads((out_root() / "stats.json").read_text(encoding="utf-8"))
    specs = [
        json.loads(line)["spec"]
        for line in (data_root() / "rico_specs" / "specs.jsonl").open(encoding="utf-8")
    ]

    leaves = [_leaves(s["screens"][0]["body"]) for s in specs]
    types: Counter[str] = Counter()
    for s in specs:
        _node_types(s["screens"][0]["body"], types)
        for slot in ("appbar", "bottomnav", "fab"):
            if slot in s["screens"][0]:
                types[slot] += 1
    tok = load_tokenizers()["gemma-4-E2B-it"]
    rng = np.random.default_rng(0)
    sample_idx = rng.choice(len(specs), size=min(5000, len(specs)), replace=False)
    tokens = [
        len(tok.encode(per_screen_texts(specs[i])[0], add_special_tokens=False).ids) for i in sample_idx
    ]
    _hist(leaves, "Elements per converted RICO screen", "elements", FIG / "elements_per_screen.png")
    _hist(
        tokens,
        "Spec tokens per screen (Gemma 4 tokenizer)",
        "tokens",
        FIG / "tokens_per_screen.png",
        line=250,
    )

    # Sample grids and stroke-class counts from the first train shard.
    first = sorted((out_root() / "train").glob("shard_*.jsonl.gz"))[0]
    imgs = []
    cls_counts: Counter[str] = Counter()
    with gzip.open(first, "rt", encoding="utf-8") as f:
        for k, line in enumerate(f):
            rec = json.loads(line)
            cls_counts.update(rec["stroke_cls"])
            if k < 16:
                imgs.append(render_ink(rec["ink"], rec["stroke_cls"], 384))
    save_grid(imgs, FIG / "synthetic_samples.png", cols=4)

    lines = [
        "# Data report",
        "",
        "Generated by `python -m s2a.data.report` from the pipeline's own outputs; "
        "nothing here is hand-edited.",
        "",
        "## 1. RICO -> UI specs",
        "",
        f"Source: RICO semantic annotations, {conv['source_screens']:,} screens "
        "(JSON hierarchies only, no screenshots).",
        "",
        "| Outcome | Screens |",
        "|---|---:|",
        *[f"| {k} | {v:,} |" for k, v in conv["reasons"].items()],
        "",
        "Kept screens satisfy: portrait, no drawer/modal overlay, mostly Latin text (ML Kit reads en-US), "
        "3-30 sketchable elements, valid against the schema after conversion.",
        "",
        f"Elements per kept screen: median {statistics.median(leaves):.0f}, p10 {_pct(leaves, 10):.0f}, "
        f"p90 {_pct(leaves, 90):.0f}.",
        "",
        f"Spec size (canonical JSON, Gemma 4 tokenizer, {len(tokens):,} random screens): median "
        f"**{statistics.median(tokens):.0f}** tokens/screen, p90 {_pct(tokens, 90):.0f}, max {max(tokens)} "
        f"(target: median < 250). ![tokens](figures/tokens_per_screen.png)",
        "",
        "Node types in converted specs:",
        "",
        "| Type | Count |",
        "|---|---:|",
        *[f"| {k} | {v:,} |" for k, v in types.most_common()],
        "",
        "## 2. Splits (by app)",
        "",
        "Apps are assigned to train/val/test by a hash of the package name, so no app appears in two splits.",
        "",
        "| Split | Apps | Specs | Samples | 1 screen | 2 screens | 3 screens | Failed "
        "| Strokes/sample (median, p90) |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---|",
    ]
    for s in SPLITS:
        st = synth[s]
        sp = st.get("strokes_per_sample", {})
        lines.append(
            f"| {s} | {st['apps']:,} | {st['specs']:,} | {st.get('ok', 0):,} | {st.get('screens_1', 0):,} | "
            f"{st.get('screens_2', 0):,} | {st.get('screens_3', 0):,} | {st.get('failed', 0):,} | "
            f"{sp.get('median', 0):.0f}, {sp.get('p90', 0):.0f} |"
        )
    train_types = synth["train"]["element_types"]
    total_cls = sum(cls_counts.values())
    lines += [
        "",
        "## 3. Synthetic sketches",
        "",
        "Every sample is laid out by our own randomised layout (not the app's pixels) and drawn per the "
        "sketch legend, so sketch and gold spec always agree. Noise model (configs/data.yaml):",
        "",
        "| Parameter | Range |",
        "|---|---|",
        *[f"| pen.{k} | {v} |" for k, v in cfg["pen"].items()],
        *[f"| transform.{k} | {v} |" for k, v in cfg["transform"].items()],
        f"| order.shuffled_prob | {cfg['order']['shuffled_prob']} |",
        f"| canvas.drawn_frame_prob | {cfg['canvas']['drawn_frame_prob']} |",
        f"| layout.list_mark_prob | {cfg['layout']['list_mark_prob']} |",
        f"| multiscreen.share | {cfg['multiscreen']['share']} |",
        *[f"| augment.{k} | {v} |" for k, v in cfg["augment"].items()],
        "",
        "Element types in the train split:",
        "",
        "| Element | Count |",
        "|---|---:|",
        *[f"| {k} | {v:,} |" for k, v in train_types.items()],
        "",
        f"Stroke classes in the first train shard ({total_cls:,} strokes): "
        + ", ".join(f"{k} {v / total_cls:.1%}" for k, v in cls_counts.most_common())
        + ".",
        "",
        "Random training samples (shape strokes black, handwriting blue, arrows red, drawn frames grey):",
        "",
        "![samples](figures/synthetic_samples.png)",
        "",
        "![elements](figures/elements_per_screen.png)",
        "",
        "## 4. Example converted spec",
        "",
        "```json",
        canonical_json(specs[int(sample_idx[0])]),
        "```",
        "",
    ]
    lines += photo_section(cfg)
    (DOCS / "data_report.md").write_text("\n".join(lines), encoding="utf-8")
    print(f"wrote {DOCS / 'data_report.md'}")


if __name__ == "__main__":
    main()
