# PROGRESS

Living log of what is done, what is next, blockers, and exact commands to reproduce.
Newest phase at the top of "Phase log".

## Status board

| Phase | State |
|---|---|
| P0 Recon | done (2026-10-10) |
| P1 Spec, renderer, exporter | in progress |
| P2 Walking skeleton | pending |
| P3 Data pipeline | pending |
| P4 Recognizer | pending |
| P5 Collect mode | pending |
| P6 Layout LLM | pending |
| P7 Evaluation | pending |
| P8 Demo polish | pending |
| P9 Docs | pending |
| P10 GRPO (stretch) | pending |

## Open requests for Akshit (batched)

See the bottom of this file ("Needs you"). Work continues on everything that does not depend on them.

---

## P0 Recon findings (2026-10-10)

### Laptop (detected)

| Item | Value |
|---|---|
| OS | Windows 11 Home 25H2 (10.0.26200) |
| CPU | AMD Ryzen 7 4800H, 8 cores / 16 threads |
| RAM | 15.4 GB |
| GPU | NVIDIA RTX 3050 Ti Laptop, **4 GB VRAM**, driver 591.86 (CUDA 13.1) + AMD Radeon iGPU |
| Disk | **C: 9.9 GB free** (critical), D: 175 GB free |
| Repo location | `C:\Users\akshi\OneDrive\Desktop\Mini 7` (inside OneDrive) |

Consequences:
- The 4 GB GPU is enough to **train the stroke recognizer locally** (2-5M params), but not to fine-tune Gemma 4 E2B (Unsloth quotes 8-10 GB for E2B LoRA). LLM training goes to Colab/Kaggle notebooks.
- C: is nearly full. All heavy artefacts (venv, uv cache, RICO, synthetic data, checkpoints, HF cache) go to `D:\sketch2app-data` via `S2A_DATA_ROOT`. Nothing large is written inside the repo.
- OneDrive syncs every file in the repo, including Gradle and Flutter build output. That risks file-lock errors during Android builds. Recommendation in "Needs you".

### Toolchain (detected)

| Tool | Version / state |
|---|---|
| Python | 3.12.10 (system), uv 0.11.2 |
| Project venv | `D:\sketch2app-data\venv` (Python 3.12, created by uv) |
| git / gh | 2.52.0 / 2.96.0 (logged in as Akshit-afk-dot) |
| Flutter | 3.44.0 stable, Dart 3.12.0, DevTools 2.57.0 |
| Android SDK | `%LOCALAPPDATA%\Android\sdk`: platforms 34, 35, 36, 36.1; build-tools 35.0.0-37.0.0; NDK 28.2.13676358; CMake 3.22.1 |
| Android issues | `cmdline-tools` missing; licence status unknown (only `android-sdk-license` present); `adb` 37.0.0 exists but is not on PATH |
| JDK | Android Studio JBR, OpenJDK 21.0.10 |
| Visual Studio | 2026 Community 18.4, install incomplete (only matters for Flutter Windows-desktop builds, which we do not need) |
| WSL | not installed (matters only for litert-torch, which is Linux-only; we run it in Colab) |
| Devices | `adb devices`: none connected |

### Models (verified on the Hugging Face API, 2026-10-10)

| Model | HF id | Licence | Gated | Notes |
|---|---|---|---|---|
| Gemma 4 E2B instruct | `google/gemma-4-E2B-it` @ `3e22461f` | Apache-2.0 | no | 5.12B stored params (2B "effective": per-layer embeddings plus vision/audio encoders); base `google/gemma-4-E2B` |
| Gemma 4 E2B LiteRT-LM (stock) | `litert-community/gemma-4-E2B-it-litert-lm` @ `b3ca0d2f` | Apache-2.0 | no | `gemma-4-E2B-it.litertlm` ~2.58 GB, mixed 2/4/8-bit; CPU and GPU builds |
| Qwen3.5 0.8B instruct | `Qwen/Qwen3.5-0.8B` @ `2fc06364` | Apache-2.0 | no | 0.87B params; base `Qwen/Qwen3.5-0.8B-Base` |
| Unsloth mirror | `unsloth/gemma-4-E2B-it` | Apache-2.0 | no | used by Unsloth notebooks |

### On-device LLM path (verified)

- **Conversion**: Google's "Convert and run a fine-tuned model" tutorial uses
  `litert-torch export_hf --model=<merged HF dir> --output_dir=<out> --externalize_embedder`.
  The litert-torch repo has `export_hf/model_ext/gemma4` and `model_ext/qwen3_5`, so both target models have exporters.
  litert-torch requires **Linux** (README), so conversion runs in the Colab/Kaggle notebook.
  Versions: `litert-torch` 0.9.4 (stable), `litert-torch-nightly` 0.10.0.dev20261009 (what the tutorial installs).
- **Desktop check**: `litert-lm` 0.18.0 CLI: `litert-lm run model.litertlm --prompt=...`.
- **Known risk**: litert-torch issue #1013 reports a fine-tuned Gemma 4 E2B export that loads but loses fidelity versus the HF model. We will measure HF-vs-litertlm parity on our own validation set before trusting it.
- **Flutter**: Google's LiteRT-LM docs list Flutter as "community, via flutter_gemma". flutter_gemma is now renamed **`flutter_edge_ai` 2.1.1** + **`flutter_edge_ai_litertlm` 1.11.0** (MIT, released 2026-10-08/09). It supports `ModelType.gemma4` and `ModelType.qwen35` `.litertlm` files. Constraints: Android **minSdk 30**, **arm64-v8a only**, `maxTokens` is the whole context window (>= 1024).
- **Constrained decoding**: LiteRT-LM advertises constrained decoding for tool calls; no JSON-schema grammar API found. Plan: schema validation -> repair -> retry at lower temperature -> heuristic fallback.

### LLM fine-tuning (verified)

- Unsloth 2026.10.3 officially supports Gemma 4 E2B LoRA (docs: unsloth.ai/docs/models/gemma-4/train; 8-10 GB VRAM). It wraps TRL's `SFTTrainer`.
- TRL 1.15.0, PEFT 0.21.2, transformers 5.19.0, bitsandbytes 0.50.2.
- **Decision**: Unsloth + TRL `SFTTrainer` in the notebook (best-documented Gemma 4 path; fits a free T4 with QLoRA); the notebook keeps a plain TRL + PEFT branch as fallback if Unsloth breaks.

### Stroke recognizer runtime (decision)

| Option | Converter | Flutter plugin | Verdict |
|---|---|---|---|
| LiteRT | litert-torch 0.9.4 (Linux only) | `flutter_litert` 3.9.3 (community) | rejected |
| ONNX Runtime Mobile | `torch.onnx.export` (runs on Windows) | `flutter_onnxruntime` 1.9.0 (2026-10-06; ORT 1.28.0 on Android) | **chosen** |

Why ONNX Runtime: export and parity tests run natively on this Windows laptop; dynamic stroke-count axis without padding tricks; the Python wheel `onnxruntime==1.28.0` is the same runtime version the plugin ships on Android, so the parity test compares like with like; and it avoids loading a second copy of the LiteRT native libraries next to LiteRT-LM.

### Handwriting

- `google_mlkit_digital_ink_recognition` 0.16.1 (2026-08-17), needs Dart ^3.12.0 / Flutter >= 3.44.0 (matches). Android and iOS only. Language pack (`en-US`) downloaded once through `DigitalInkRecognizerModelManager`, then offline.

### Data

- RICO official bucket is live: `https://storage.googleapis.com/crowdstf-rico-uiuc-4540/rico_dataset_v0.1/semantic_annotations.zip` (157.8 MB; JSON hierarchies plus masks). Screenshots (`unique_uis.tar.gz`, 6.5 GB) are **not needed**. App mapping for the by-app split will come from RICO's metadata CSVs (verified in P3).
- Licence: recorded in LICENSES.md after verification in P3.

### Pinned dependency plan

Python (local, `ml/pyproject.toml`; torch from the cu130 index):

| Package | Pin | Use |
|---|---|---|
| torch | 2.14.1 (+cu130) | recognizer training |
| onnx / onnxscript | 1.23.2 / 0.7.2 | export |
| onnxruntime | 1.28.0 | parity with Android ORT 1.28.0 |
| numpy | 2.5.3 | |
| jsonschema | 4.26.0 | spec validation |
| pyyaml | 6.0.3 | configs |
| pillow / matplotlib | 12.3.0 / 3.11.2 | sample grids, charts |
| apted | 1.0.3 | tree edit distance |
| flask | 3.1.3 | LAN server |
| tokenizers | pinned in P1 | token counting |
| pytest / ruff / mypy | 9.1.1 / 0.16.10 / 2.4.0 | tests and linting |

Notebook only (Colab/Kaggle, pinned in the notebook's first cell): unsloth 2026.10.3, trl 1.15.0, peft 0.21.2, transformers 5.19.0, bitsandbytes 0.50.2, datasets 5.1.0, litert-torch-nightly 0.10.0.dev20261009, litert-lm 0.18.0.

Flutter (`app/pubspec.yaml`):

| Package | Pin | Use |
|---|---|---|
| google_mlkit_digital_ink_recognition | 0.16.1 | handwriting |
| flutter_onnxruntime | 1.9.0 | stroke recognizer |
| flutter_edge_ai / flutter_edge_ai_litertlm | 2.1.1 / 1.11.0 | on-device LLM |
| share_plus | 13.3.1 | export via share sheet |
| archive | 4.3.0 | zip export |
| path_provider | 2.1.6 | app storage |
| shared_preferences | 2.5.6 | settings |
| http | 1.6.0 | LAN mode |
| rfw | 1.1.4 | evaluated, not used (see DESIGN.md) |

Syntax highlighting: `flutter_highlight` is unmaintained (2021, Dart < 3), so the Code tab will use a small in-repo Dart tokenizer.

---

## Phase log

### P0 Recon — done

Reproduce:
```bash
nvidia-smi
flutter doctor -v
"$LOCALAPPDATA/Android/sdk/platform-tools/adb.exe" devices -l
curl -s https://huggingface.co/api/models/google/gemma-4-E2B-it
```
Venv:
```bash
export UV_CACHE_DIR=/d/sketch2app-data/uv-cache
uv venv /d/sketch2app-data/venv --python 3.12
uv pip install --python /d/sketch2app-data/venv/Scripts/python.exe torch==2.14.1 --index-url https://download.pytorch.org/whl/cu130
uv pip install --python /d/sketch2app-data/venv/Scripts/python.exe -e "ml[dev]"
```

---

## Needs you

(filled in as phases hit steps only you can do)
