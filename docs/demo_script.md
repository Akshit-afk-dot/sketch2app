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

## The 5 minutes

| Time | Say | Do |
|---|---|---|
| 0:00 | "Draw an app, get a working Flutter app, offline." | Show airplane mode on. Open the **cheat sheet** briefly. |
| 0:30 | "Two screens: a login and a list." | Tap **New screen** once. Draw on screen 1: image box (X), "Email" + box, "Password" + box, button "Sign in". Screen 2: band with "Items", one card with an image + "Item", write "x5". Draw an arrow from Sign in to screen 2. |
| 2:00 | "Convert." | Tap **Convert**. Point at the debug overlay: recognized boxes and types on the canvas, timings per stage. |
| 2:30 | "It is interactive." | In the preview, type in Email, tap **Sign in** -> list screen with 5 items; back arrow. |
| 3:00 | "And it is real code." | **Code** tab: `login_screen.dart` with `goTo(context, '/items')`. Tap **Export** -> share sheet (zip). |
| 3:30 | "How it works." | Pipeline in one breath: strokes -> our transformer recognizer (2M params, ONNX) -> ML Kit handwriting -> fine-tuned LLM writes a compact spec (4x fewer tokens than Dart) -> interpreter + exporter. |
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
| App crashes | | Re-open; samples load instantly. Worst case: play the screen recording of a full run (record one the day before). |
| Export/share sheet fails | | Show the Code tab; the zip is optional for the story. |

## What to have open on the laptop

- docs/results.md, docs/data_report.md (figures), DESIGN.md (for "why" questions), the notebook (training curves).
- A terminal with the LAN server ready (only if using LAN mode).
