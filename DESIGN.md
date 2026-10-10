# DESIGN

Architecture, decisions, trade-offs and rejected alternatives. Each section says *why*, because every
choice here has to be defended in the viva. Status and numbers live in PROGRESS.md and docs/results.md.

## 1. Architecture

```
ink strokes (x,y,t) ──► stroke recognizer ──► elements (type, box, stroke ids) + arrows
                              (own model; heuristic fallback)
text groups ──► ML Kit Digital Ink ──► labels
elements + labels + arrows ──► layout model ──► UI spec JSON ──► validate/repair
                              (fine-tuned Gemma 4 E2B / Qwen3.5-0.8B; heuristic fallback)
UI spec ──► renderer (live preview)       UI spec ──► exporter (Flutter project zip)
```

Every ML stage has a deterministic heuristic twin. The twin is (a) the demo safety net and (b) the
baseline the trained model is measured against.

## 2. UI spec v1

Source of truth: `spec/schema/ui_spec.v1.schema.json`. Validators: `ml/s2a/spec/validate.py`,
`app/lib/spec/parse.dart`. Canonical serializers: `ml/s2a/spec/canonical.py`, `app/lib/spec/canonical.dart`.

### Why a spec instead of generating Dart

- **Tokens.** Measured on the 11 example apps (`python -m s2a.spec.tokens`, docs/results/spec_tokens.json):
  median ~122 tokens per screen in canonical form with the Gemma 4 tokenizer. On-device decode time grows
  linearly with output tokens, so the representation size directly sets latency. The spec-vs-Dart token
  ratio is measured in P7 (ablation).
- **Validity by construction.** A closed vocabulary can be validated and repaired. Free-form Dart can
  fail to compile in unbounded ways, and we cannot run the Dart compiler on the phone.
- **Two consumers.** The same spec drives the live preview (interpreted) and the export (code-generated).
- **Evaluation.** A tree is comparable with tree-edit distance; code is not.

### Changes from the starting format (changelog)

| Change | Reason |
|---|---|
| `appbar`, `bottomnav`, `fab` are screen slots, not body nodes | They map 1:1 to `Scaffold.appBar/bottomNavigationBar/floatingActionButton`; a body containing an appbar has no meaning, so the schema forbids it instead of the renderer guessing. |
| Defaults are omitted in canonical form (`text.s=body`, `btn.variant=primary`, `input.secure/multiline=false`) | Shorter targets, and one spelling per meaning so exact-match and SFT targets are unambiguous. |
| Fixed key order per node type; no whitespace | Unique serialization. Python and Dart produce byte-identical output (shared fixtures). |
| Closed icon set (39 names) mapped to Material icons | The model picks from a list instead of inventing names the exporter cannot resolve. `circle` is the generic doodle. |
| `go` also allowed on `card`, `text`, `icon`, `avatar`, nav items and `fab` | Sketches draw arrows from any element; list cards opening a detail screen is the most common case. |
| `img.h` is percent of screen height (5-100) | Resolution-independent and already quantized for the LLM. |
| `appbar.icons` (0-4 icon nodes) | Search/menu/cart icons in the top band are very common in sketches and in RICO. |
| Limits: 1-8 screens, 1-40 children, list n <= 50, grid n <= 60 / 2-4 cols, depth <= 10, no list/grid inside a repeated item | Bounds keep generation short and rendering safe; nested repetition has no clean sketch convention. |
| Strings: 1-80 chars, no control characters | Keeps escaping identical across languages and blocks prompt-injected newlines in labels. |

### Error codes (shared by both validators)

`json` (Dart only, malformed text), `schema` (structure), `dup_id`, `bad_go`, `nesting`, `depth`.
Semantic checks run only when the structure is valid, in both languages.

## 3. Renderer: direct interpreter, not rfw

Decision: `app/lib/render/spec_renderer.dart` interprets the typed spec with one `switch` over a sealed
class hierarchy.

rfw (`package:rfw` 1.1.4) was evaluated and rejected:
- rfw needs its own library format plus a "local widget library" that we would have to write anyway
  for stateful controls (checkbox, radio, switch) and navigation, so it adds a translation layer
  (spec -> rfw text -> widgets) with no gain for a closed, 17-type vocabulary.
- Type safety: Dart 3 sealed classes make the interpreter's `switch` exhaustive, so adding a node type
  is a compile error until both renderer and exporter handle it. rfw's dynamic data model loses that.
- rfw's strength (server-pushed UI updates without app releases) does not apply to an offline app.

Preview fidelity tricks:
- The preview owns a `Navigator` (screens are routes, so the system back gesture and app bar back
  arrow work) and a `MediaQuery` sized to the preview pane, so `img` heights match a phone.
- `lib/render/sketch_widgets.dart` (stateful controls, grid, placeholder image, paragraph, `goTo`) is
  copied verbatim into every exported project. A test fails if the embedded copy drifts, so preview
  and exported app behave identically.

## 4. Exporter

`app/lib/export/` is pure Dart (no Flutter imports): `exportProject(spec)` returns a sorted
path -> content map. Deterministic: same spec, same bytes.

- **Code IR.** Widgets are built as a small expression tree (`code.dart`) that knows which nodes are
  const-capable. The printer places `const` only on the outermost const-capable node, which satisfies
  `prefer_const_constructors` without triggering `unnecessary_const`, and breaks lines in the same
  tall style as `dart format` (one argument per line, trailing comma, 80 columns).
- **Exported lint level is stricter than the Flutter template** (`prefer_const_constructors`,
  `prefer_const_literals_to_create_immutables`, `prefer_single_quotes` on top of flutter_lints 6), so
  "zero analyzer issues" is a meaningful claim.
- **Android folder** is the Flutter 3.44 template reduced to text files: the Gradle wrapper jar and
  scripts are regenerated by the Flutter tool (the template itself gitignores them), and the PNG
  launcher icons are replaced by a vector drawable. The zip stays small and fully text-diffable.
- **Routes**: first screen is `/`, others `/<id>`; `goTo(context, route)` in sketch_widgets.dart.

## 5. Spec -> widget mapping (shared contract)

Renderer (`spec_renderer.dart`) and exporter (`screen_codegen.dart`) implement exactly this table.

| Spec | Widget |
|---|---|
| screen | `Scaffold(appBar?, body: SafeArea(SingleChildScrollView(padding 16, child: body)), bottomNavigationBar?, floatingActionButton?)` |
| appbar | `AppBar(title: Text, actions: [IconButton...])` |
| bottomnav | `NavigationBar` (selected = item whose `go` is this screen), tap -> `goTo(replace: true)` |
| fab | `FloatingActionButton(child: Icon)` |
| col | `Column(stretch, spacing 12)` |
| row | `Row(spacing 8)`; children wrapped in `Expanded` except icon/avatar |
| card | `Card(Padding 12, Column(stretch, spacing 8))`; with `go`: `InkWell` inside, `Clip.antiAlias` |
| list | `Column(stretch, spacing 8, [for i < n: item])` |
| grid | `GridOf(columns, count, itemBuilder)` (rows of `Expanded`, content-sized) |
| text | h1 `headlineSmall`, h2 `titleLarge`, body default, caption `bodySmall`, link `TextButton`; non-link with `go`: `InkWell` |
| para | `Paragraph(lines)` (lorem ipsum, `maxLines`) |
| btn | primary `FilledButton`, secondary `OutlinedButton`, text `TextButton` |
| input | `TextField(OutlineInputBorder, labelText, obscureText if secure, 3-5 lines if multiline)` |
| check / radio / switch | `CheckField` / `RadioField` (`RadioGroup` API) / `SwitchField` |
| img | `PlaceholderImage(heightFactor = h/100)` |
| icon | `IconButton(Icon(Icons.<material id>))` |
| avatar | `CircleAvatar(Icon(Icons.person))`; with `go`: `InkWell(customBorder: CircleBorder())` |
| divider / spacer | `Divider()` / `SizedBox(height: 24)` |

Unlinked buttons stay enabled (`() {}`) so the preview feels like a real app.

## 6. Runtime choices (from P0 recon)

- **Stroke recognizer runtime: ONNX Runtime** (`flutter_onnxruntime` 1.9.0, ORT 1.28.0 on Android)
  over LiteRT. Export and parity tests run on the Windows dev laptop (litert-torch is Linux-only), the
  stroke axis can stay dynamic, the Python wheel `onnxruntime==1.28.0` equals the Android runtime for
  parity, and it avoids a second copy of LiteRT native libraries next to LiteRT-LM.
- **On-device LLM runtime: LiteRT-LM** through `flutter_edge_ai` + `flutter_edge_ai_litertlm`, the
  Flutter path Google's LiteRT-LM docs point to. Requires Android minSdk 30 and arm64-v8a.
- **Fine-tuning: Unsloth + TRL** (documented Gemma 4 E2B support, fits a free T4 with QLoRA).

## 7. Recognition (P2-P4)

**Rule-based recognizer** (`app/lib/recognize/heuristic_recognizer.dart`): each legend line is one rule
over per-stroke features (closedness, area ratio, straightness, y-turns, RDP corners), all relative to the
frame width so zoom does not matter. Key feature: enclosed area / bbox area is pi/4 for *any* ellipse and
~1 for a rectangle, an aspect-invariant circle-vs-box test. It is the fallback and the baseline.

**Learned recognizer** (`ml/s2a/recognizer/`, 1.98M parameters, 8 MB ONNX):
- *Why strokes, not pixels:* ink arrives already segmented, ordered and timed. A sequence of ~100 strokes
  is cheaper than a CNN on a megapixel canvas and keeps information an image loses (an outline is one fast
  closed stroke; letters are many small strokes close in time).
- *Per-stroke encoder:* 32 arc-length-resampled points (shape relative to the stroke's own box + direction)
  through a 1D CNN, plus 16 geometric/timing features. *Context:* 4-layer pre-norm transformer over strokes
  with 2D sinusoidal position (stroke centre/size) and drawing-order encodings: a stroke's meaning depends on
  its neighbours (text inside a box -> button; an X inside -> image).
- *Heads:* stroke class (frame/text/shape/arrow), element type per stroke (pooled per group), and a
  pairwise affinity q_i . k_j ("same element?"). The number of elements is unknown, so grouping is
  framed as pair classification + **average-linkage clustering** (resists chaining, unlike connected
  components). Element boxes are the union of grouped strokes: exact, so no box regression head.
- *Training:* AdamW + warmup/cosine, bf16 autocast, length-bucketed batches; model selection on typed
  element F1 of decoded val sketches (the reported metric, not the loss).
- *Runtime:* ONNX Runtime 1.28 (same version in Python and in the Android plugin). Features and decoder are
  Dart ports tested against Python fixtures; an in-app self-test compares on-device ORT outputs with PyTorch.

## 8. Data (P3)

- **RICO -> spec:** recursive **XY-cut** (classic document layout analysis) recovers nested rows/columns
  from component bounds; greedy row grouping flattened thumbnail+title+description into one row.
  A final `sanitize` pass makes every tree schema-valid. 42,313 of 66,261 screens kept.
- **Our own layout, not the app's pixels:** the sketcher lays out each spec with sampled sizes/gaps, so the
  sketch always matches its gold spec; whatever had to change (truncated labels, dropped overflow, a list
  drawn as 2 repeats instead of "xN") changes the gold too.
- **Legend-coverage augmentation:** RICO has *no* divider label and 115 bottom navs in 42k screens; we insert
  dividers, bottom navs, FABs, radio and switch rows (labels from the corpus) so every legend item is
  learnable. Recorded in configs/data.yaml and the data report.
- **Splits by app** (hash of the package name): no app in two splits, so layouts cannot leak.
- **Human-like noise:** correlated pen jitter (smoothed, not white noise), corner overshoot/rounding,
  multi-stroke and re-traced outlines, broken strokes, per-frame rotation/scale/shear, sloppy per-element
  offsets, shuffled drawing order, realistic timing; Hershey single-stroke fonts for text.

## 9. Layout model (P6)

- **Prompt format** (`prompt.py` / `prompt.dart`, shared fixtures): integer-percent coordinates per frame,
  reading order, short ids; arrows resolved geometrically to "element k -> screen n" before the model sees
  them (geometry is not the LLM's job). ~8 tokens per element.
- **Training inputs are noisy on purpose:** the trained recognizer's measured errors on val (per-type miss
  rate, type confusions, false positives, box jitter) are replayed on gold element lists, plus handwriting
  typos; 20% stay clean. Otherwise the model never learns to recover from real recognizer output.
- **Inference policy** (`llm_layout.dart`), identical for LAN and on-device: generate at T=0.3 -> validate
  -> repair (strip prose, close truncated JSON, drop unknown keys/types, one-option radio -> checkbox,
  drop dangling links) -> retry at T=0 (greedy) -> the pipeline falls back to the rule-based builder.
- **LAN server** only hosts the model; with llama.cpp the output is grammar-constrained to the spec's JSON
  Schema, so syntax errors and unknown node types cannot occur.
- **On-device:** fine-tuned model -> merged -> `litert-torch export_hf` -> `.litertlm`, run by LiteRT-LM via
  `flutter_edge_ai` (Android 11+, arm64). Not bundled in the APK (GBs); pushed once with adb.

## 10. Collect mode (P5)

Participants draw one *part* of one element per step (outline, then label) and tap Next, so every stroke's
element and role are labelled exactly with no manual annotation. Records use the synthetic sample format.
Targets come from test-split apps. Real data is split **by participant** (frozen, ~40% held out), so the
real test set never shares a drawing style with fine-tuning data.

## 11. Rejected alternatives (running list)

| Alternative | Why not |
|---|---|
| Generate Dart directly with the LLM | More tokens, unbounded failure modes, no on-device compiler to check it. Kept as an ablation. |
| rfw for the preview | See section 3. |
| Image-based recognizer (CNN on a rendered sketch) | Strokes carry order, timing and grouping for free and are tiny; P4 will justify in detail. |
| `GridView` for grids | Forces a fixed cell aspect ratio, so card content overflows; `GridOf` sizes rows to content. |
| Copying PNG launcher icons into exports | Binary files in an otherwise text-only template; a vector drawable works from API 21. |
| LiteRT (TFLite) for the recognizer | litert-torch export is Linux-only; ONNX exports on Windows, keeps a dynamic stroke axis, and avoids a second LiteRT runtime next to LiteRT-LM. |
| Box-regression head | Element boxes are exactly the union of the grouped strokes. |
| Connected components for grouping | One confident wrong edge merges two elements; average linkage does not chain. |
| Greedy row grouping for RICO | Flattened nested layouts; XY-cut recovers the hierarchy. |
| Using RICO pixel bounds for sketches | Sketch and simplified spec would disagree; our own layout keeps them consistent. |
| Training the LLM on clean element lists | The model would never see recognizer errors; measured noise is replayed instead. |
| Icon identity in the spec (search, cart...) | The legend has no way to draw which icon; gold uses generic `circle` (menu and fab excepted). |
