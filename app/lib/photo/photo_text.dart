/// Labels for a photographed sketch: ML Kit text recognition (OCR) on the photo, matched to elements.
///
/// Why OCR here and Digital Ink for drawn sketches: Digital Ink reads pen trajectories, and a photo's
/// pseudo-strokes have no real trajectory (letters merge, order and timing are made up). OCR reads the
/// pixels instead, once per photo, with the bundled Latin model (offline from the first launch). Words
/// are assigned to the element whose handwriting strokes they overlap; an element no word matches falls
/// back to Digital Ink on its pseudo-strokes.
library;

import 'dart:math' as math;

import '../handwriting/handwriting.dart';
import '../ink/ink_model.dart';

/// One OCR word in the vectorizer's (photo work-size) coordinates.
class OcrWord {
  const OcrWord(this.text, this.box);
  final String text;
  final Box box;
}

/// Words lying mostly inside [area] (grown by a third of its height: OCR boxes and the strokes'
/// skeleton box differ by about a pen width), in reading order, joined by spaces; null when none.
String? wordsIn(List<OcrWord> words, Box area) {
  final zone = area.inflate(area.h / 3);
  final hits = [
    for (final w in words)
      if (w.text.trim().isNotEmpty &&
          (zone.intersect(w.box)?.area ?? 0) >=
              0.5 * math.max(w.box.area, 1e-6))
        w,
  ];
  if (hits.isEmpty) return null;
  // Lines: words whose vertical centres are within half the median word height of the line's first word.
  final heights = [for (final w in hits) w.box.h]..sort();
  final tol = heights[heights.length ~/ 2] / 2;
  hits.sort((a, b) => a.box.cy.compareTo(b.box.cy));
  final lines = <List<OcrWord>>[];
  for (final w in hits) {
    if (lines.isNotEmpty && (w.box.cy - lines.last.first.box.cy).abs() <= tol) {
      lines.last.add(w);
    } else {
      lines.add([w]);
    }
  }
  return [
    for (final line in lines)
      for (final w in line..sort((a, b) => a.box.x.compareTo(b.box.x)))
        w.text.trim(),
  ].join(' ');
}

class PhotoTextReader implements HandwritingReader {
  const PhotoTextReader(this.words, this.fallback);

  final List<OcrWord> words;

  /// Digital Ink on the pseudo-strokes, for elements no OCR word matched.
  final HandwritingReader fallback;

  @override
  Future<bool> isReady() async => true;

  @override
  Future<bool> prepare({bool wifiOnly = false}) async => true;

  @override
  Future<String?> read(List<InkStroke> strokes, Box area) async {
    if (strokes.isEmpty) return null;
    final box = strokes.map((s) => s.box).reduce((a, b) => a.union(b));
    final text = wordsIn(words, box);
    if (text != null) return text;
    try {
      return await fallback.isReady()
          ? await fallback.read(strokes, area)
          : null;
    } on Object {
      return null; // no Digital Ink on this platform: the layout stage uses a generic label
    }
  }
}
