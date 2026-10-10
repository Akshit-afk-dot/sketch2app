# Sketch2App

Sketch app screens with a finger or stylus on an Android tablet or classroom board, and get a working,
interactive preview plus a clean Flutter project — fully offline after a one-time setup.

```
ink strokes ──► stroke recognizer (our transformer, ONNX) ──► elements + arrows
                ML Kit handwriting (on-device)            ──► labels
elements ──► layout model (fine-tuned Gemma 4 E2B / Qwen3.5-0.8B, or rules) ──► UI spec JSON
UI spec ──► live preview (Flutter interpreter)   UI spec ──► exported Flutter project (zip)
```

Every ML stage has a rule-based twin: the demo never dead-ends, and the twin is the baseline in
[docs/results.md](docs/results.md). Design decisions and their reasons: [DESIGN.md](DESIGN.md).
Status and exact reproduction commands per phase: [PROGRESS.md](PROGRESS.md).

## Repository

| Path | What |
|---|---|
| `spec/` | UI spec v1: JSON Schema, 11 example apps, cross-language fixtures (spec, naming, prompt) |
| `app/` | Flutter app (canvas, recognizers, handwriting, layout engines, preview, exporter, Collect mode) |
| `ml/` | Python package `s2a`: data pipeline, recognizer, layout-model tooling, LAN server, metrics |
| `notebooks/layout_sft.ipynb` | Colab/Kaggle notebook: LoRA fine-tuning + evaluation + export of the layout model |
| `scripts/` | `build_apk.ps1`, `push_model.ps1`, `fix_if_braces.py` |
| `docs/` | results, data report, demo script, viva notes, report outline |

## Setup (Windows, as developed; Linux/macOS work the same with `/` paths)

Requirements: Flutter 3.44 (Dart 3.12), Android SDK + JDK 17+ (Android Studio's), Python 3.12, `uv`,
git. A CUDA GPU helps for recognizer training (a 4 GB laptop GPU is enough); LLM fine-tuning uses Colab/Kaggle.

```bash
# Heavy files (datasets, checkpoints, caches) go to a data folder outside the repo:
export S2A_DATA_ROOT=D:/sketch2app-data UV_CACHE_DIR=D:/sketch2app-data/uv-cache
uv venv $S2A_DATA_ROOT/venv --python 3.12
PY=$S2A_DATA_ROOT/venv/Scripts/python.exe          # bin/python on Linux/macOS
uv pip install --python $PY torch==2.14.1 --index-url https://download.pytorch.org/whl/cu130
uv pip install --python $PY -e "ml[dev]"
cd app && flutter pub get
```

## Run the app

```bash
cd app && flutter test                                   # 110+ tests, no device needed
powershell -ExecutionPolicy Bypass -File scripts/build_apk.ps1 -Mode release   # builds on D:, not in the repo
adb install -r D:/sketch2app-data/apk/sketch2app-release.apk
```

First launch (with internet): tap **Download** to install the English handwriting pack. After that the app
works in airplane mode. Optional on-device layout model: `scripts/push_model.ps1 -Model <file.litertlm>`.
Optional LAN layout model: `python -m s2a.layout.server --backend llamacpp --model <file.gguf>` on the laptop,
then Settings > Layout > LAN LLM.

## Reproduce the data and models

By downloading RICO you accept its research terms (see [LICENSES.md](LICENSES.md)).

```bash
cd ml
$PY -m s2a.data.download all          # RICO semantic annotations (158 MB) + Hershey fonts
$PY -m s2a.data.rico_convert          # 66,261 screens -> 42,313 specs
$PY -m s2a.data.build_dataset         # synthetic sketches, split by app (~1 h on 8 cores)
$PY -m s2a.data.report                # docs/data_report.md
$PY -m s2a.recognizer.cache           # feature cache
$PY -m s2a.recognizer.train --name v1                     # ~45 min on an RTX 3050 Ti
$PY -m s2a.recognizer.export --ckpt $S2A_DATA_ROOT/runs/recognizer/v1/best.pt   # ONNX + parity + fixtures
$PY -m s2a.recognizer.evaluate --method heuristic --split test
$PY -m s2a.recognizer.evaluate --method onnx --split test
$PY -m s2a.layout.recognized --split val && $PY -m s2a.layout.noise measure   # recognizer error rates
$PY -m s2a.layout.recognized --split test
$PY -m s2a.layout.sft_data            # SFT data + bundle for the notebook
$PY -m s2a.layout.evaluate --method heuristic --input gold --split test
$PY -m s2a.layout.evaluate --method heuristic --input recognizer --split test
# Layout model: notebooks/layout_sft.ipynb on Colab/Kaggle with the bundle, or locally on a 4 GB GPU:
$PY -m s2a.layout.train_local --name qwen35-0.8b-lora-v1 --examples 4000 --epochs 2   # ~6 h on an RTX 3050 Ti
$PY -m s2a.layout.evaluate --method predictions --input gold --name finetuned_qwen \
    --pred $S2A_DATA_ROOT/runs/layout/qwen35-0.8b-lora-v1/predictions_gold.jsonl     # and --input recognizer
$PY -m s2a.e2e --n 200 --analyze 20   # ink -> recognizer -> layout -> render -> export -> flutter analyze
$PY -m s2a.results                    # docs/results.md
```

### Real sketches (Collect mode)

```bash
$PY -m s2a.data.collected import <export.zip>      # validates, splits by participant (frozen, ~40% held out)
$PY -m s2a.recognizer.evaluate --method onnx --data real --split test
$PY -m s2a.layout.recognized --data real --split train && $PY -m s2a.layout.recognized --data real --split test
$PY -m s2a.layout.noise measure --data real --split train      # real error rates for the SFT noise model
$PY -m s2a.layout.sft_data --noise ../docs/results/recognizer_noise_real_train.json   # adds eval_real_test_*
$PY -m s2a.layout.evaluate --method heuristic --input recognizer --data real
```

## Tests and linters

```bash
cd ml && $PY -m pytest -q && $PY -m ruff check . && $PY -m mypy s2a
cd app && flutter analyze && flutter test
```

## Licences

Code: this repository. Models: Gemma 4 and Qwen3.5 are Apache-2.0. Data: RICO research terms. Hershey fonts:
see LICENSES.md for the required acknowledgement.
