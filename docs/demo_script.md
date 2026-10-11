# Demo script (5 minutes) and fallback plan

## Before the viva (the evening before and 30 minutes before)

1. Install the latest APK: `adb install -r D:/sketch2app-data/apk/sketch2app-release.apk`.
2. Open the app once with internet: tap **Download** on the handwriting banner (one-time ~20 MB pack).
3. On-device LLM (if used): `powershell -ExecutionPolicy Bypass -File scripts/push_model.ps1 -Model <layout.litertlm>`,
   then Settings > Layout > On-device LLM shows "Layout model found". Convert one sample to warm it up.
4. LAN LLM backup: on the laptop `python -m s2a.layout.server --backend llamacpp --model <gguf>`;
   Settings > Layout > LAN LLM > Test shows "Connected".
5. Settings: **Learned recognizer** on, **Debug overlay** on (shows boxes and per-stage timings).
6. Run Settings > **Recognizer self-test**: note the max |diff| (proves the phone runs the same model as Python).
7. **Airplane mode on.** Verify: sample "Login -> list" > Convert works, and a drawn sketch works.
8. Charge the device; disable screen timeout; close other apps.
9. **Paper sketch** for photo mode: plain white A4, dark felt-tip or ballpoint, the legend from the cheat
   sheet. Two phone outlines (Login: image box, "Email" + box, "Password" + box, button "Sign in";
   List: top band "Items", a card with image + "Item", "x5"), an arrow from Sign in to the list screen.
   Photograph it once at home in good light and keep that photo in the gallery (fallback).

## The 5 minutes

| Time | Say | Do |
|---|---|---|
| 0:00 | "Sketch an app on paper, get a working Flutter app, offline." | Show airplane mode on. Hold up the paper sketch. |
| 0:20 | "One photo." | Camera button > **Take a photo** from straight above. The extracted strokes appear over the faded photo; conversion starts by itself. Point at the debug chips: photo decode / vectorize / OCR times. |
| 1:00 | "It is interactive." | Preview: type in Email, tap **Sign in** -> list with 5 items; back arrow. |
| 1:30 | "And it is real code." | **Code** tab: `login_screen.dart` with `goTo(context, '/items')`. Tap **Export** -> share sheet (zip). |
| 2:00 | "Or draw directly." | Clear, draw a small settings screen with the stylus (title band, two "label + switch" rows, a button); Convert. |
| 3:00 | "How it works." | Photo -> our vectorizer (paper, threshold, thinning, tracing) -> strokes; strokes -> our transformer recognizer (2M params, ONNX; a photo-tuned copy for photos) -> ML Kit labels (OCR on photos) -> fine-tuned LLM or rules write a compact spec (4x fewer tokens than Dart) -> interpreter + exporter. |
| 4:15 | "Measured." | Open docs/results.md on the laptop: recognizer vs rules, layout model vs rules, validity rates. |
| 4:45 | "Limits." | Icons are generic (the legend cannot express which icon); no styling/colours; English handwriting only. |

## Fallback plan (what to do if X fails live)

| Failure | Symptom | Do this |
|---|---|---|
| Handwriting pack missing | Labels show "Button"/"Text" | Say so; the structure still works. Next time: download before airplane mode. |
| Learned recognizer misbehaves | Odd boxes in the overlay | Settings > Learned recognizer **off** (rule-based recognizer, always available), Convert again. |
| On-device LLM slow or fails | Spinner > 20 s, or falls back | Nothing to do: after the timeout the app uses the rule-based layout automatically. Or switch to LAN LLM. |
| LAN server unreachable | "Not reachable" | Settings > Layout > **Rules**. Offline guarantee: rules need nothing. |
| My drawing is not recognized well | Wrong screen | Menu > **Sample: Login -> list (2 screens)** > Convert (bundled ink, known to work). |
| Photo comes out empty or messy | "No drawing found", or many stray strokes | More light / no shadow, retake from straight above; or **Choose from gallery** > the photo taken the day before. Stray strokes: eraser, then Convert. |
| Labels wrong on the photo | Generic "Button"/"Text" | Expected for scrawled words; say OCR reads print best; the structure and navigation are the point. |
| App crashes | | Re-open; samples load instantly. Worst case: play the screen recording of a full run (record one the day before). |
| Export/share sheet fails | | Show the Code tab; the zip is optional for the story. |

## What to have open on the laptop

- docs/results.md, docs/data_report.md (figures), DESIGN.md (for "why" questions), the notebook (training curves).
- A terminal with the LAN server ready (only if using LAN mode).
