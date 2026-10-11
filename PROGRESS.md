# PROGRESS

Living log of what is done, what is next, blockers, and exact commands to reproduce.
Newest phase at the top of "Phase log".

## Status board (2026-10-11)

| Phase | State |
|---|---|
| P0 Recon | done |
| P1 Spec, renderer, exporter | done; 11/11 example exports pass `flutter analyze` and their tests |
| P2 Walking skeleton | done; APK builds; on-device run pending (needs device) |
| P3 Data pipeline | done: 42,266 synthetic samples (by-app splits), legend-coverage augmentation, data report |
| P4 Recognizer | done: typed F1 0.980 vs 0.487 rule-based (synthetic test); ONNX + Dart parity |
| P5 Collect mode | done (app + import + per-participant split); real sketches pending (needs people) |
| P6 Layout LLM | SFT data, notebook, LAN server, on-device path done; local Qwen3.5-0.8B QLoRA at step 200/500 (val tree sim 0.677), resuming |
| P7 Evaluation | rule-based end-to-end done (200/200 render, 20/20 analyze); LLM rows pending training |
| P8 Demo polish | 4 built-in samples, debug overlay, cheat sheet; device rehearsal pending |
| P9 Docs | README, DESIGN, demo script, viva notes, report outline; kept current |
| P10 GRPO (stretch) | not started |
| **P11 Photo input** | app + vectorizer + synthetic-photo data + photo study done; photo model training next |

## Needs you (batched)

1. **Device info**: model, RAM, Android version of your tablet/phone; is an Android smart board available? (LiteRT-LM needs Android 11+, arm64.)
2. **Install and try the APK** (USB debugging on): `"%LOCALAPPDATA%/Android/sdk/platform-tools/adb.exe" install -r D:/sketch2app-data/apk/sketch2app-release.apk`.
   Open once with internet and tap Download (handwriting pack). Then in airplane mode: menu > Sample: Login -> list > Convert; draw something; **camera button > photo of a paper sketch** (plain paper, dark pen, see the cheat sheet). Tell me what breaks.
3. **Photo study** (the real-world number for photo mode): menu > Photo study. 5-10 classmates x 4-6 tasks each, drawn on paper and photographed; then Export and send me the zip (`python -m s2a.data.real_photos import <zip>`).
4. **Collect mode** (real drawn sketches, 100-200): menu > Collect data; export the zip the same way.
5. **Layout LLM on Colab/Kaggle** (Gemma 4 E2B rows): upload `D:/sketch2app-data/llm/sketch2app_llm_bundle.zip` and run `notebooks/layout_sft.ipynb`; bring back the small results zip.
6. **Disk**: move the repo out of OneDrive to D: (OneDrive syncs build files and locks Gradle caches).
7. **RICO terms**: you are the "Researcher" under RICO's research terms (LICENSES.md); don't publish RICO-derived data.

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
| google_mlkit_text_recognition | 0.17.1 | OCR for photo labels (bundled `com.google.mlkit:text-recognition:16.0.1`, offline) |
| image_picker | 1.2.4 | camera / gallery for photo mode |
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

### P11 Photo input (2026-10-11) — app, data and evaluation path done; photo model training next

Asked for by the user: take a photo of a paper sketch, upload it in the app, convert locally.
- Design (DESIGN.md section 11): photo -> pseudo-strokes with a pure-Dart vectorizer -> the same
  recognizer/layout pipeline; labels by on-device OCR (ML Kit text recognition, bundled model).
- `lib/photo/vectorize.dart` (9 tests), `photo_import.dart`, `photo_text.dart` (OCR -> element labels);
  camera button on the canvas, photo shown faded under the editable strokes; Photo study page.
- Training data: `s2a.data.build_photo` renders synthetic samples as photos (pen, paper, light, shadow,
  rotation, perspective, table, blur, noise, JPEG, stray marks), vectorizes them with the app's own code
  (compiled `tool/batch.dart`, ~100 ms per photo) and labels pseudo-strokes by majority element group.
  Smoke build (60 photos): ~1% noise strokes, 1-3% of elements lose all ink to the vectorizer.
  Full build (12k/1k/1k) running.
- Decoders drop NONE-type groups (noise) and add one implicit screen when no frame exists. Effect on
  the pen-ink model: 1 element in 1,000 test sketches.
- Next: cache + fine-tune the photo model (`configs/recognizer_photo.yaml`, `--init` ink model), evaluate
  rule-based vs ink model (zero-shot) vs photo model on synthetic photos, end-to-end on photos, APK.

### P7 Evaluation — rule-based end-to-end done

- `python -m s2a.e2e --n 200 --analyze 20`: spec valid 200/200, **render 200/200** (was 197/200: a secure
  multi-line input asserted in Flutter, a 15-item row overflowed; both fixed in renderer and exporter),
  **20/20 exports pass `flutter analyze`**; laptop medians: recognizer 48.7 ms, rule-based layout 0.46 ms.
- Re-measure on an idle laptop before the final results: recognizer latency (the 2026-10-11 re-run under
  load read 82 ms and was discarded).

### P6 Layout model — tooling done, local fine-tune in progress

- SFT data from noisy element lists (recognizer error rates measured on val), notebook for Colab/Kaggle
  (Unsloth + TRL), LAN server (llama.cpp with JSON-schema constrained decoding), on-device LiteRT-LM path.
- Local QLoRA of Qwen3.5-0.8B on the 4 GB RTX 3050 Ti (`s2a.layout.train_local`): TRL's trainer needs
  Triton (Linux only), so a plain PEFT loop computes logits only for completion positions in checkpointed
  chunks (peak 1.9 GB). Validation tree similarity 0.34 / 0.54 / 0.58 / 0.68 at steps 50-200. The run was
  interrupted at step 210 by a session end; it now checkpoints at every validation and resumes with
  `--resume` (from step 200, fresh optimizer moments, 10-step LR re-warmup).
- Baselines (synthetic test, rule-based builder): gold input tree sim 0.816, type F1 0.873, link F1 0.934;
  recognizer input 0.801 / 0.865 / 0.687.

### P5 Collect mode — done (needs participants)

- Step-by-step drawing of test-split targets gives exact stroke labels; zip export; Python import with a
  frozen per-participant split (40% held out). Every evaluation script takes `--data real`.

### P4 Recognizer — done

- 1.98M-param stroke transformer, 12 epochs in 44 min on the RTX 3050 Ti; best val typed F1 0.984.
- Synthetic test (1,000 sketches): typed F1 **0.980** (rule-based 0.487), any-type F1 0.983 (0.663),
  stroke accuracy 0.9996 (0.850). ONNX 8.05 MB, PyTorch vs ORT 1.28 max |diff| 9.9e-5, 14.2 ms laptop CPU;
  Dart features/decoder match Python on the fixtures.

### P2 Walking skeleton (heuristic path) — code done, device test pending

- Canvas (pen/finger, stylus-only mode, two-finger pan/zoom, eraser, undo/redo, multiple template frames), heuristic recognizer, ML Kit handwriting reader, heuristic layout builder, pipeline with per-stage timings and fallbacks, split view (>= 840 px) / tabs, live preview, code tab, zip export via share sheet, settings, cheat sheet, built-in sample sketches.
- 85+ Dart tests pass (`flutter test`), analyzer clean. Release APK builds: `D:/sketch2app-data/apk/sketch2app-release.apk` (37.7 MB, arm64).
- Lesson: building inside the repo filled C: (Gradle caches, ~3 GB) and failed. Builds now go through `scripts/build_apk.ps1` (mirror on D:, GRADLE_USER_HOME on D:, `kotlin.incremental=false` because project and Pub cache are on different drives).

### P3 Data pipeline — done

- RICO -> specs: 42,313 of 66,261 screens kept (drops: overlay 10,552; too few elements 7,702; non-Latin 1,980; too many 1,979; empty 1,616; landscape 119); 0 schema-invalid. XY-cut layout recovery + sanitize pass.
- Synthetic sketcher (legend-faithful, smooth pen noise, Hershey text, multi-screen arrows), by-app splits (val 830 apps / test 753 apps), shards + eval exports. 77 Python tests pass.
- Reproduce: `python -m s2a.data.download all && python -m s2a.data.rico_convert && python -m s2a.data.build_dataset --workers 6 && python -m s2a.data.report`
- Full build done (2026-10-10): train 33,560 samples / 6,279 apps, val 4,440 / 830 apps, test 4,265 / 753 apps (48 of 42,313 failed layout). Multi-screen: train 5,311 two-screen + 4,763 three-screen. Strokes per sample median 94, p90 ~271, max 1,086. Size on D: train 1.1 GB, val 142 MB, test 137 MB, eval exports 231 MB (1,000 val + 1,000 test).
- Legend-coverage augmentation (divider, bottom nav, FAB, radio, switch, grids) and `docs/data_report.md` regenerated (2026-10-11).

### P1 Spec, legend, renderer, exporter — done

What exists:
- `spec/schema/ui_spec.v1.schema.json` (refined format; changelog in DESIGN.md section 2).
- 11 hand-written example apps in `spec/examples/` (login, signup, list, grid, profile, settings, chat, detail, form, 2-screen login->list, 3-screen shop).
- Shared conformance fixtures `spec/fixtures/{valid,invalid,canonical}`: 3 valid edge cases, 18 invalid cases (one or more per error code), expected canonical strings.
- Python: `s2a.spec` (validator = JSON Schema + semantic rules, canonical serializer, token counter). 63 pytest tests.
- Dart: `app/lib/spec` (typed sealed model, validating parser, canonical serializer), `app/lib/render` (live preview), `app/lib/export` (pure-Dart exporter with const-aware code IR, Android template). 40 Dart tests incl. 11 goldens.

Results (all from scripts, raw JSON in docs/results/):
- Python and Dart canonical serializers are byte-identical on all 14 valid fixtures (incl. unicode, quotes, backslashes).
- Spec size, 11 examples / 14 screens (`spec_tokens.json`): median **121.5** tokens/screen (Gemma 4 tokenizer), 121.0 (Qwen3.5); max 181. Pretty-printed JSON costs 2.5x more.
- Exported projects (`export_check.json`): **11/11 pass `flutter analyze`** (flutter_lints 6 + prefer_const_constructors, prefer_const_literals_to_create_immutables, prefer_single_quotes) and **11/11 pass their generated `flutter test`**, Flutter 3.44.0. The first run found 6/11 failing (`const AppBar`: AppBar has no const constructor); fixed and covered by a regression test.

Reproduce:
```bash
cd ml && $PY -m pytest -q && $PY -m ruff check s2a tests && $PY -m mypy s2a
cd ml && S2A_DATA_ROOT=D:/sketch2app-data $PY -m s2a.spec.tokens
cd ml && $PY -m s2a.spec.fixtures          # regenerate canonical fixtures after a spec change
cd app && flutter analyze && flutter test   # add --update-goldens after an intended visual change
cd app && dart run tool/gen.dart            # regenerate icons.g.dart / sketch_widgets_source.g.dart
cd app && dart run tool/export_examples.dart --out D:/sketch2app-data/exports --test
```

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

