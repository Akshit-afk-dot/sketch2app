/// Photo of a paper sketch -> ink on the canvas (+ OCR words for its labels), entirely on the device.
///
/// The photo is decoded once by the platform codec (EXIF orientation applied); the vectorizer and OCR both
/// read those same pixels, so OCR boxes and strokes share one coordinate space (the vectorizer's work
/// size, long side [photoLongSide]).
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';

import '../ink/ink_model.dart';
import 'photo_text.dart';
import 'vectorize.dart';

class PhotoSketch {
  const PhotoSketch({
    required this.image,
    required this.scale,
    required this.result,
    required this.words,
    required this.micros,
    this.ocrError,
  });

  /// The decoded photo, painted under the ink at [scale] (work px per photo px).
  final ui.Image image;
  final double scale;
  final VectorizeResult result;
  final List<OcrWord> words;

  /// Wall time per step (decode, vectorize steps, ocr) for the debug overlay.
  final Map<String, int> micros;
  final String? ocrError;

  Box get bounds => Box(0, 0, image.width * scale, image.height * scale);
}

/// [bytes]: an encoded photo (JPEG/PNG), e.g. from image_picker. [ocr] false skips text recognition
/// (tests, platforms without ML Kit).
Future<PhotoSketch> importPhoto(Uint8List bytes, {bool ocr = true}) async {
  final sw = Stopwatch()..start();
  final codec = await ui.instantiateImageCodec(bytes);
  final image = (await codec.getNextFrame()).image;
  final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final gray = GrayImage.fromRgba(
    image.width,
    image.height,
    rgba!.buffer.asUint8List(),
  ).fitWithin(photoLongSide);
  final scale = gray.width / image.width;
  final micros = <String, int>{'decode': sw.elapsedMicroseconds};
  sw.reset();
  final result = await compute(vectorize, gray);
  micros['vectorize'] = sw.elapsedMicroseconds;
  sw.reset();
  var words = const <OcrWord>[];
  String? error;
  if (ocr) {
    try {
      words = await _recognizeText(image, scale);
    } on Object catch (e) {
      error = '$e'; // labels then come from Digital Ink on the pseudo-strokes
    }
  }
  micros['ocr'] = sw.elapsedMicroseconds;
  return PhotoSketch(
    image: image,
    scale: scale,
    result: result,
    words: words,
    micros: {...micros, ...result.micros},
    ocrError: error,
  );
}

/// OCR on the decoded pixels (written as PNG, so the orientation is the one the vectorizer saw), words
/// scaled into work coordinates.
Future<List<OcrWord>> _recognizeText(ui.Image image, double scale) async {
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File(
    '${(await getTemporaryDirectory()).path}/s2a_photo_ocr.png',
  );
  await file.writeAsBytes(png!.buffer.asUint8List(), flush: true);
  final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
  try {
    final text = await recognizer.processImage(
      InputImage.fromFilePath(file.path),
    );
    return [
      for (final block in text.blocks)
        for (final line in block.lines)
          for (final w in line.elements)
            OcrWord(
              w.text,
              Box(
                w.boundingBox.left * scale,
                w.boundingBox.top * scale,
                w.boundingBox.width * scale,
                w.boundingBox.height * scale,
              ),
            ),
    ];
  } finally {
    await recognizer.close();
  }
}
