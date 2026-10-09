# Sketch2App — project memory

Offline Android (Flutter) app: sketch app screens with finger/stylus -> interactive preview -> exported Flutter project.
7th-semester B.Tech ML project; every design choice must be defensible in a viva. See DESIGN.md for the why, PROGRESS.md for status.

## Pipeline

1. Ink capture: strokes = lists of (x, y, t); several screen frames on one canvas.
2. Stroke recognizer (own model, PyTorch -> ONNX -> `flutter_onnxruntime`): per-stroke class, pairwise grouping, element type + box. Heuristic recognizer is the fallback and the baseline.
3. Handwriting: ML Kit Digital Ink (en-US pack, offline after first download).
4. Layout: element list -> canonical UI spec JSON. Fine-tuned Gemma 4 E2B (LoRA) primary, Qwen3.5-0.8B fallback, heuristic builder always available. On-device (`flutter_edge_ai_litertlm`) or LAN (Flask on the laptop).
5. Renderer: direct Dart interpreter of the spec (not rfw).
6. Exporter: pure-Dart deterministic templates -> Flutter project that passes `flutter analyze`.

## Repo layout

- `spec/` — single source of truth for the UI spec: JSON Schema, example specs, cross-language conformance fixtures.
- `ml/` — Python package `s2a` (spec tools, data pipeline, recognizer, layout LLM tooling, LAN server), `tests/`, `configs/*.yaml`.
- `app/` — Flutter app (package `sketch2app`). `lib/spec` and `lib/export` are pure Dart (no Flutter imports) so `dart run` tools can use them.
- `notebooks/` — self-contained Colab/Kaggle notebooks (LLM SFT, conversion).
- `scripts/` — device helpers (adb push, etc.).
- `docs/` — results.md (script-generated only), data_report.md, demo_script.md, viva_notes.md, report_outline.md.

## Conventions

- Heavy artefacts never go in the repo or on C: (9.9 GB free). Use `S2A_DATA_ROOT` (this laptop: `D:/sketch2app-data`). Default when unset: `<repo>/artifacts` (gitignored).
- Python: typed, small modules, docstrings that state *why*, fixed seeds, YAML configs, pytest. Lint: `ruff check`, `ruff format --check`, `mypy`.
- Dart: `flutter analyze` must be clean; tests for spec parsing, renderer, exporter.
- Spec changes: update `spec/schema`, both validators, both serializers, the conformance fixtures, and the changelog in DESIGN.md together.
- Numbers in docs/results.md come only from scripts that ran. Anything not run is marked "pending". Never estimate.
- Training data is programmatic only. Never LLM-generated.
- Pin every dependency version; verify current APIs before using them.

## Key commands

```bash
# Python env (venv lives on D:)
PY=/d/sketch2app-data/venv/Scripts/python.exe
export S2A_DATA_ROOT=D:/sketch2app-data UV_CACHE_DIR=D:/sketch2app-data/uv-cache
$PY -m pytest ml/tests -q
$PY -m ruff check ml && $PY -m ruff format --check ml && $PY -m mypy ml/s2a

# Flutter
cd app && flutter pub get && flutter analyze && flutter test
cd app && dart run tool/export_examples.dart   # exports spec/examples -> analyzes each

# adb is not on PATH on this laptop
ADB="$LOCALAPPDATA/Android/sdk/platform-tools/adb.exe"
```
