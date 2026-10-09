/// Handwriting reading for element labels via ML Kit Digital Ink Recognition (on-device).
///
/// Why ML Kit instead of our own model: reading arbitrary English handwriting needs far more real data
/// than a 4-week project can collect; ML Kit runs offline once its ~20 MB `en-US` pack is downloaded.
/// Our own models handle what ML Kit cannot: which strokes are text and which element they label.
library;

import 'package:google_mlkit_digital_ink_recognition/google_mlkit_digital_ink_recognition.dart'
    as mlkit;

import '../ink/ink_model.dart';
import '../recognize/elements.dart';

abstract interface class HandwritingReader {
  /// True when reading works offline right now (model pack present).
  Future<bool> isReady();

  /// One-time setup; may need network. Returns whether the reader is ready afterwards.
  Future<bool> prepare({bool wifiOnly = false});

  /// Best reading of [strokes], or null when nothing legible.
  Future<String?> read(List<InkStroke> strokes, Box area);
}

/// Fills `text` of every element that carries handwriting.
Future<void> readElementTexts(
  HandwritingReader reader,
  ElementList list,
  Map<int, InkStroke> strokes,
) async {
  await Future.wait([
    for (final e in list.elements)
      if (e.type.hasText && e.textStrokes.isNotEmpty)
        reader
            .read([for (final id in e.textStrokes) ?strokes[id]], e.box)
            .then((t) => e.text = t),
  ]);
}

final _listMark = RegExp(r'^\s*[xX×*]\s*\d{1,2}\s*$');

class MlKitHandwritingReader implements HandwritingReader {
  MlKitHandwritingReader({this.languageCode = 'en-US'})
    : _recognizer = mlkit.DigitalInkRecognizer(languageCode: languageCode);

  final String languageCode;
  final mlkit.DigitalInkRecognizer _recognizer;
  final _models = mlkit.DigitalInkRecognizerModelManager();

  @override
  Future<bool> isReady() => _models.isModelDownloaded(languageCode);

  @override
  Future<bool> prepare({bool wifiOnly = false}) async {
    if (await isReady()) return true;
    return _models.downloadModel(languageCode, isWifiRequired: wifiOnly);
  }

  @override
  Future<String?> read(List<InkStroke> strokes, Box area) async {
    if (strokes.isEmpty) return null;
    final ink = mlkit.Ink()
      ..strokes = [
        for (final s in strokes)
          mlkit.Stroke()
            ..points = [
              for (final p in s.points)
                mlkit.StrokePoint(x: p.x - area.x, y: p.y - area.y, t: p.t),
            ],
      ];
    final candidates = await _recognizer.recognize(
      ink,
      context: mlkit.DigitalInkRecognitionContext(
        writingArea: mlkit.WritingArea(width: area.w, height: area.h),
      ),
    );
    if (candidates.isEmpty) return null;
    // "x5" is easily read as "xs" or "x 5"; if any top candidate is a list mark, the writer meant one.
    final mark = candidates
        .take(3)
        .where((c) => _listMark.hasMatch(c.text))
        .firstOrNull;
    final text = (mark ?? candidates.first).text.trim();
    return text.isEmpty ? null : text;
  }

  Future<void> close() => _recognizer.close();
}

/// Used where ML Kit does not exist (tests, desktop builds) or before the language pack is downloaded:
/// the pipeline still runs and the layout falls back to generic labels.
class NoHandwritingReader implements HandwritingReader {
  const NoHandwritingReader();
  @override
  Future<bool> isReady() async => false;
  @override
  Future<bool> prepare({bool wifiOnly = false}) async => false;
  @override
  Future<String?> read(List<InkStroke> strokes, Box area) async => null;
}
