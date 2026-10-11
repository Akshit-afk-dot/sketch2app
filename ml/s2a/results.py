"""Assemble docs/results.md from the JSON files the evaluation scripts wrote to docs/results/.

    python -m s2a.results

Every number comes from a file produced by a script run; a missing file prints "pending" in its row.
Nothing here computes or estimates a metric itself.
"""

from __future__ import annotations

import json
from typing import Any

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

from s2a.paths import REPO_ROOT

RES = REPO_ROOT / "docs" / "results"
FIG = REPO_ROOT / "docs" / "figures"
PENDING = "pending"


def load(name: str) -> dict[str, Any] | None:
    p = RES / name
    return json.loads(p.read_text(encoding="utf-8")) if p.exists() else None


def f(v: Any, digits: int = 3) -> str:
    if v is None:
        return "n/a"
    if isinstance(v, float):
        return f"{v:.{digits}f}"
    return str(v)


def recognizer_rows(split: str, data: str = "synth") -> list[str]:
    rows = []
    suffix = split if data == "synth" else f"real_{split}"
    for name, label in (("heuristic", "Rule-based (baseline)"), ("onnx", "Learned (ONNX, ships in app)"),
                        ("onnx_realft", "Learned + real-data fine-tune")):  # fmt: skip
        r = load(f"recognizer_{name}_{suffix}.json")
        if r is None:
            rows.append(f"| {label} | {PENDING} | | | | | |")
            continue
        a, t = r["detection_any_type"], r["detection_typed"]
        rows.append(
            f"| {label} | {f(a['f1'])} | {f(t['precision'])} | {f(t['recall'])} | **{f(t['f1'])}** | "
            f"{f(r['stroke_accuracy'])} | {f(r['meta']['laptop_ms_per_sketch']['median'], 1)} |"
        )
    return rows


LAYOUT_METHODS = (
    ("heuristic", "Rule-based builder (baseline)"),
    ("heuristic_llmsubset", "Rule-based builder, on the LLM rows' samples"),
    ("fewshot_gemma", "Gemma 4 E2B base, 3-shot"),
    ("finetuned_gemma", "Gemma 4 E2B + LoRA"),
    ("finetuned_qwen", "Qwen3.5-0.8B + LoRA"),
)


def layout_rows(inp: str, split: str = "test") -> list[str]:
    rows = []
    for name, label in LAYOUT_METHODS:
        r = load(f"layout_{name}_{inp}_{split}.json")
        if r is None:
            if name != "heuristic_llmsubset":  # only shown once an LLM run exists
                rows.append(f"| {label} | {PENDING} | | | | | | | |")
            continue
        rows.append(
            f"| {label} | {r['meta']['samples']} | {f(r['json_valid'])} | {f(r['schema_valid'])} | "
            f"**{f(r['tree_similarity'])}** | "
            f"{f(r['type_f1'])} | {f(r.get('link_f1'))} | {f(r['label_accuracy'])} | "
            f"{f(r['meta'].get('ms_per_sample_median'), 1)} |"
        )
    return rows


def e2e_rows() -> list[str]:
    rows = []
    for name, label in LAYOUT_METHODS:
        if name == "heuristic_llmsubset":
            continue
        r = load(f"e2e_{name}_test.json")
        if r is None:
            rows.append(f"| {label} | {PENDING} | | | | | |")
            continue
        ms = r["laptop_ms_median"]
        rows.append(
            f"| {label} | {r['sketches']} | {f(r['spec_valid_rate'])} | **{f(r['render_success_rate'])}** | "
            f"{r['exported_analyze_pass']} | {f(ms['recognizer'], 1)} | {f(ms['layout'], 1)} |"
        )
    return rows


def photo_section() -> list[str]:
    """Photo mode: recognizer on synthetic photos, end to end on them, and the real Photo study."""
    rows = []
    for name, label in (
        ("heuristic", "Rule-based (baseline)"),
        ("onnx", "Ink model, zero-shot"),
        ("onnx_photomodel", "Photo model (ink model fine-tuned on photos)"),
    ):
        r = load(f"recognizer_{name}_photo_test.json")
        if r is None:
            rows.append(f"| {label} | {PENDING} | | | | | |")
            continue
        a, t = r["detection_any_type"], r["detection_typed"]
        rows.append(
            f"| {label} | {f(a['f1'])} | {f(t['precision'])} | {f(t['recall'])} | **{f(t['f1'])}** | "
            f"{f(r['stroke_accuracy'])} | {f(r['meta']['laptop_ms_per_sketch']['median'], 1)} |"
        )
    e = load("e2e_heuristic_photo_test.json")
    e2e = (
        f"| {e['sketches']} | {f(e['spec_valid_rate'])} | **{f(e['render_success_rate'])}** | "
        f"{e['exported_analyze_pass']} | {f(e['laptop_ms_median'].get('vectorize'), 0)} | "
        f"{f(e['laptop_ms_median']['recognizer'], 1)} | {f(e['laptop_ms_median']['layout'], 1)} |"
        if e
        else f"| {PENDING} | | | | | | |"
    )
    spec_rows = []
    for inp, label in (
        ("gold", "Perfect elements (layout stage alone)"),
        ("recognizer", "Photo model output"),
    ):
        r = load(f"layout_heuristic_{inp}_photo_test.json")
        spec_rows.append(
            f"| {label} | **{f(r['tree_similarity'])}** | {f(r['type_f1'])} | {f(r.get('link_f1'))} | "
            f"{f(r['screens_correct'])} |"
            if r
            else f"| {label} | {PENDING} | | | |"
        )
    dev = load("photo_real_device.json")
    lap = load("photo_real_laptop_recognizer_photo.json")
    real = [
        "| Run | Photos (people) | Tree sim. | Type F1 | Link F1 | Screens | Labels |",
        "|---|---:|---:|---:|---:|---:|---:|",
    ]
    for label, r in (
        ("On the device (photo model + OCR)", dev),
        ("Laptop re-run (photo model, no OCR)", lap),
    ):
        if r is None:
            real.append(f"| {label} | {PENDING} (needs the Photo study) | | | | | |")
            continue
        m = r["meta"]
        real.append(
            f"| {label} | {m['photos']} ({m['participants']}) | **{f(r['tree_similarity'])}** | "
            f"{f(r['type_f1'])} | {f(r.get('link_f1'))} | {f(r['screens_correct'])} | "
            f"{f(r.get('label_accuracy'))} |"
        )
    lat = (
        ", ".join(f"{k} {f(v, 0)}" for k, v in dev["latency_ms_median"].items())
        if dev
        else f"{PENDING} (needs the Photo study)"
    )
    return [
        "## 5. Photo mode (paper sketches)",
        "",
        "Photos are turned into strokes by the app's vectorizer, then recognized like drawn ink. Synthetic",
        "photos: 1,000 test-split sketches (apps never seen in training) rendered as phone photos of paper.",
        "",
        "### Recognizer on synthetic photos",
        "",
        "| Method | Any-type F1 | Typed P | Typed R | Typed F1 | Stroke acc. | Laptop ms/sketch |",
        "|---|---:|---:|---:|---:|---:|---:|",
        *rows,
        "",
        "### End to end on synthetic photos (rule-based layout, oracle labels)",
        "",
        "| Sketches | Spec valid | Rendered | Exports passing analyze | Vectorize ms | Recognizer ms | Layout ms |",
        "|---:|---:|---:|---:|---:|---:|---:|",
        e2e,
        "",
        "### Specs from synthetic photos (rule-based layout, oracle labels)",
        "",
        "| Input to the layout stage | Tree sim. | Type F1 | Link F1 | Screens correct |",
        "|---|---:|---:|---:|---:|",
        *spec_rows,
        "",
        "### Real paper sketches (Photo study: target app drawn on paper, scored against its spec)",
        "",
        *real,
        "",
        f"Device latency per stage (median ms): {lat}.",
        "",
    ]


def recognizer_chart() -> str | None:
    h, m = load("recognizer_heuristic_test.json"), load("recognizer_onnx_test.json")
    if not (h and m):
        return None
    types = [t for t, v in m["per_type"].items() if v["matched_gold"]]

    def acc(r: dict[str, Any]) -> list[float]:
        return [float(r["per_type"][t]["type_accuracy"] or 0) for t in types]

    fig, ax = plt.subplots(figsize=(9, 3.4), dpi=120)
    x = range(len(types))
    ax.bar([i - 0.2 for i in x], acc(h), 0.4, label="rule-based", color="#9aa0a6")
    ax.bar([i + 0.2 for i in x], acc(m), 0.4, label="learned", color="#4f5bd5")
    ax.set_xticks(list(x), types, rotation=45, ha="right")
    ax.set_ylabel("type accuracy (IoU-matched)")
    ax.set_ylim(0, 1.05)
    ax.legend()
    ax.set_title("Recognizer: per-type accuracy on synthetic test")
    fig.tight_layout()
    FIG.mkdir(parents=True, exist_ok=True)
    path = FIG / "recognizer_per_type.png"
    fig.savefig(path)
    plt.close(fig)
    return "figures/recognizer_per_type.png"


def main() -> None:
    tokens, export = load("spec_tokens.json"), load("export_check.json")
    lines = [
        "# Results",
        "",
        "Generated by `python -m s2a.results` from `docs/results/*.json`; every number comes from a script run.",
        f"Rows marked **{PENDING}** have not been run yet. Synthetic test = 1,000 sketches from apps never seen "
        "in training (split by app); real test = held-out participants from Collect mode.",
        "",
        "## 1. Stroke recognizer",
        "",
        "Detection: a predicted element matches a gold element at IoU >= 0.5. *Any-type F1* ignores the type;",
        "*typed* requires the type too. Stroke accuracy = frame/text/shape/arrow per stroke.",
        "",
        "### Synthetic test (1,000 sketches)",
        "",
        "| Method | Any-type F1 | Typed P | Typed R | Typed F1 | Stroke acc. | Laptop ms/sketch |",
        "|---|---:|---:|---:|---:|---:|---:|",
        *recognizer_rows("test"),
        "",
        "### Real sketches (held-out participants)",
        "",
        "| Method | Any-type F1 | Typed P | Typed R | Typed F1 | Stroke acc. | Laptop ms/sketch |",
        "|---|---:|---:|---:|---:|---:|---:|",
        *recognizer_rows("test", "real"),
        "",
    ]
    chart = recognizer_chart()
    if chart:
        lines += [f"![per-type accuracy]({chart})", ""]
    parity = load("recognizer_parity.json")
    lines += [
        "Export and parity: "
        + (
            f"ONNX {parity['size_mb']} MB; PyTorch vs ONNX Runtime {parity['ort_version']} max |diff| "
            f"{parity['max_abs_diff']:.1e}; laptop CPU {parity['laptop_cpu_ms_median']:.1f} ms/sketch "
            "(Dart feature/decoder parity: app/test/recognizer_parity_test.dart)."
            if parity
            else PENDING
        ),
        "",
        "## 2. Layout (element list -> UI spec)",
        "",
        "Tree similarity = 1 - TED / max(|T|) (APTED, structure only); type F1 over leaf element types; link F1",
        "only over samples whose gold spec has navigation links.",
        "",
        "### Input: gold element lists (layout stage in isolation)",
        "",
        "| Method | Samples | JSON valid | Schema valid | Tree sim. | Type F1 | Link F1 | Labels | ms/sample |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|",
        *layout_rows("gold"),
        "",
        "### Input: trained recognizer output (realistic errors)",
        "",
        "| Method | Samples | JSON valid | Schema valid | Tree sim. | Type F1 | Link F1 | Labels | ms/sample |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|",
        *layout_rows("recognizer"),
        "",
        "### Input: trained recognizer output on real sketches (held-out participants)",
        "",
        "| Method | Samples | JSON valid | Schema valid | Tree sim. | Type F1 | Link F1 | Labels | ms/sample |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|",
        *layout_rows("recognizer", "real_test"),
        "",
        "## 3. Spec format and export",
        "",
    ]
    if tokens:
        g = tokens["summary"]["gemma-4-E2B-it"]
        lines += [
            f"- Spec size on the 11 hand-written examples: median {g['per_screen_canonical']['median']:.0f} "
            f"Gemma 4 tokens per screen (max {g['per_screen_canonical']['max']}); pretty-printed JSON costs "
            f"{g['pretty_over_canonical']:.1f}x more.",
        ]
        if "dart_over_canonical" in g:
            lines.append(
                f"- **Ablation, spec vs direct Dart:** the generated Dart for the same apps (screens + main.dart) "
                f"costs **{g['dart_over_canonical']:.1f}x** the tokens of the canonical spec (output tokens set "
                "decode time). Latency of direct-Dart generation: pending (needs the trained LLM)."
            )
    else:
        lines.append(f"- Spec size: {PENDING}")
    lines.append(
        f"- Exported projects passing `flutter analyze` (stricter lints): "
        f"{export['summary']['analyze_pass']}/{export['summary']['projects']}, generated tests passing "
        f"{export['summary'].get('test_pass', 'n/a')}/{export['summary']['projects']} (Flutter {export['summary']['flutter']})."
        if export
        else f"- Export check: {PENDING}"
    )
    lines += [
        "- RICO-derived specs: see docs/data_report.md (median tokens per real screen).",
        "",
        "## 4. End-to-end and on-device",
        "",
        "Synthetic test sketches through the whole pipeline on the laptop (`python -m s2a.e2e`): ink -> learned",
        "recognizer (ONNX) -> layout -> spec -> preview render (phone size, overflow counts as failure) -> export",
        "-> `flutter analyze` on the first 20 exported projects. Handwriting is an oracle here (gold labels on",
        "matched elements): ML Kit only runs on Android, so its accuracy and latency are measured on the device.",
        "",
        "| Layout | Sketches | Spec valid | Rendered | Exports passing analyze | Recognizer ms | Layout ms |",
        "|---|---:|---:|---:|---:|---:|---:|",
        *e2e_rows(),
        "",
        "| Measure | Value |",
        "|---|---|",
        f"| Latency per stage on the Android device(s) | {PENDING} (needs device) |",
        f"| Peak memory on device | {PENDING} (needs device) |",
        f"| Render success rate on real sketches | {PENDING} (needs Collect data) |",
        f"| Layout model size (.litertlm / GGUF) | {PENDING} (needs notebook run) |",
        "",
        *photo_section(),
        "## 6. Ablations",
        "",
        "| Ablation | Status |",
        "|---|---|",
        f"| Noise augmentation on/off (layout model) | {PENDING} |",
        f"| Recognizer with/without real-data fine-tuning | {PENDING} (needs Collect data) |",
        "| Spec vs direct Dart (tokens) | see section 3 |",
        "",
    ]
    (REPO_ROOT / "docs" / "results.md").write_text("\n".join(lines), encoding="utf-8")
    print("wrote docs/results.md")


if __name__ == "__main__":
    main()
