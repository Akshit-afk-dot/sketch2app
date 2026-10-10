# Project report outline

Each chapter lists what to write and where the material already is. Figures and numbers come from
docs/results.md and docs/data_report.md (script-generated).

## 1. Introduction (2-3 pages)
- Motivation: prototyping apps on tablets/classroom boards; offline (schools, privacy, no cloud cost).
- Problem statement: sketch -> interactive preview + compilable Flutter project, on-device, in seconds.
- Contributions: (1) stroke-level transformer recognizer with pairwise grouping; (2) compact UI spec + fine-tuned
  small LLM for layout; (3) a fully offline Android pipeline with deterministic fallbacks; (4) a programmatic
  dataset (RICO -> specs -> human-like synthetic sketches) and a Collect-mode protocol for real labelled sketches.
- Report structure.

## 2. Background and related work (3-4 pages)
- Sketch/screenshot-to-code: pix2code, sketch2code-style systems, GUI datasets (RICO, Screen2Words).
- Online handwriting and sketch recognition (stroke-based vs image-based); transformers on sets/sequences.
- Small on-device LLMs (Gemma 4, Qwen3.5), LoRA/QLoRA, quantization, LiteRT-LM.
- Layout analysis (XY-cut), tree edit distance (Zhang-Shasha, APTED).
- Gap: offline, on-device, measurable, with honest baselines.

## 3. System design (4-5 pages) — DESIGN.md §1-6
- Architecture diagram; stage interfaces (ink.v1, elements.v1, ui_spec.v1 schemas in spec/schema/).
- UI spec design and the changelog from the starting format; canonical serialization; token measurements.
- Renderer (direct interpreter vs rfw) and exporter (const-aware code IR, template).
- Fallback policy at every stage; runtime choices (ONNX Runtime, LiteRT-LM, ML Kit).

## 4. Data (4 pages) — docs/data_report.md, DESIGN.md §8
- RICO conversion (component mapping, XY-cut, sanitizing, filters with counts).
- Synthetic sketch generation: legend, layout, noise model (table from configs/data.yaml), augmentation.
- Splits by app; dataset statistics; sample grid figure.
- Collect mode protocol and the real dataset (participants, sketches, split by participant).

## 5. Stroke recognizer (5 pages) — DESIGN.md §7, ml/s2a/recognizer/
- Features, architecture, heads, grouping by average linkage (pseudo-code), training setup.
- Results vs the rule-based baseline: detection P/R/F1, typed F1, stroke accuracy, per-type chart, confusion.
- Export (ONNX), parity checks, on-device latency and size.
- Real-data results and fine-tuning ablation.

## 6. Layout model (5 pages) — DESIGN.md §9, ml/s2a/layout/, notebooks/layout_sft.ipynb
- Prompt format; SFT data with measured noise; LoRA/QLoRA setup; early stopping on tree similarity.
- Inference policy (validate, repair, retry, fallback); constrained decoding in LAN mode.
- Results: rule-based vs base few-shot vs fine-tuned Gemma 4 E2B vs fine-tuned Qwen3.5-0.8B, on gold
  element lists and on real recognizer output; validity, tree similarity, type/link F1, latency.
- Ablation: noise augmentation on/off; spec vs direct Dart (tokens, latency).

## 7. Application (3 pages) — app/lib/
- Canvas (stylus/finger, pan/zoom, frames), split view, preview, code view, export, settings, Collect mode.
- On-device and LAN modes; offline verification (airplane mode).
- End-to-end latency per stage on laptop and devices; memory; exported projects passing flutter analyze.

## 8. Evaluation summary and discussion (2-3 pages) — docs/results.md
- What worked, what did not; error analysis with example sketches; synthetic-to-real gap.

## 9. Limitations and future work (1-2 pages) — docs/viva_notes.md Q29-30
- Generic icons, no styling, English only, data size; GRPO stretch; icon vocabulary; iOS.

## 10. Conclusion (1 page)

## Appendices
- A. UI spec JSON Schema and example specs. B. Sketch legend (cheat sheet). C. Hyper-parameters
  (configs/*.yaml, notebook config cell). D. Reproduction commands (README). E. Licences (LICENSES.md).
