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

## 7. Rejected alternatives (running list)

| Alternative | Why not |
|---|---|
| Generate Dart directly with the LLM | More tokens, unbounded failure modes, no on-device compiler to check it. Kept as an ablation. |
| rfw for the preview | See section 3. |
| Image-based recognizer (CNN on a rendered sketch) | Strokes carry order, timing and grouping for free and are tiny; P4 will justify in detail. |
| `GridView` for grids | Forces a fixed cell aspect ratio, so card content overflows; `GridOf` sizes rows to content. |
| Copying PNG launcher icons into exports | Binary files in an otherwise text-only template; a vector drawable works from API 21. |
