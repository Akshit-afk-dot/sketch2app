import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sketch2app/handwriting/handwriting.dart';
import 'package:sketch2app/ink/ink_model.dart';
import 'package:sketch2app/photo/photo_import.dart';
import 'package:sketch2app/photo/photo_text.dart';
import 'package:sketch2app/pipeline/pipeline.dart';
import 'package:sketch2app/recognize/elements.dart';
import 'package:sketch2app/spec/spec.dart';
import 'package:sketch2app/ui/canvas/sketch_controller.dart';

class _FakeReader implements HandwritingReader {
  int calls = 0;
  @override
  Future<bool> isReady() async => true;
  @override
  Future<bool> prepare({bool wifiOnly = false}) async => true;
  @override
  Future<String?> read(List<InkStroke> strokes, Box area) async {
    calls++;
    return 'ink';
  }

  @override
  bool get readsImage => false;
}

class _Failing implements StrokeRecognizer {
  @override
  String get name => 'broken';
  @override
  Future<ElementList> recognize(InkDocument doc) async =>
      throw StateError('no model');
}

InkStroke _stroke(double x, double y, double w, double h) =>
    InkStroke(0, [InkPoint(x, y, 0), InkPoint(x + w, y + h, 10)]);

/// A photo-like PNG: grey paper with a dark phone outline, a button and a heading line.
Future<Uint8List> _sketchPng() async {
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 600, 800),
    Paint()..color = const Color(0xFFDDDDDD),
  );
  final pen = Paint()
    ..color = const Color(0xFF333333)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 4;
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      const Rect.fromLTWH(150, 60, 300, 640),
      const Radius.circular(20),
    ),
    pen,
  );
  canvas.drawRect(const Rect.fromLTWH(190, 520, 220, 60), pen);
  canvas.drawLine(const Offset(190, 140), const Offset(400, 140), pen);
  final image = await rec.endRecording().toImage(600, 800);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  return png!.buffer.asUint8List();
}

void main() {
  group('OCR words -> element labels', () {
    const words = [
      OcrWord('in', Box(160, 52, 30, 20)),
      OcrWord('Sign', Box(100, 50, 50, 22)),
      OcrWord('Email', Box(100, 150, 60, 20)),
      OcrWord('far', Box(600, 600, 40, 20)),
    ];

    test('words inside the area, in reading order', () {
      expect(wordsIn(words, const Box(95, 45, 120, 30)), 'Sign in');
      expect(wordsIn(words, const Box(95, 145, 80, 30)), 'Email');
      expect(wordsIn(words, const Box(300, 300, 50, 20)), isNull);
    });

    test('a word only grazing the area is not taken', () {
      expect(wordsIn(words, const Box(185, 75, 100, 40)), isNull);
    });

    test(
      'reader uses OCR first and Digital Ink only when no word matches',
      () async {
        final ink = _FakeReader();
        final reader = PhotoTextReader(words, ink);
        expect(
          await reader.read([_stroke(100, 50, 110, 22)], const Box(0, 0, 1, 1)),
          'Sign in',
        );
        expect(ink.calls, 0);
        expect(
          await reader.read([_stroke(300, 300, 40, 20)], const Box(0, 0, 1, 1)),
          'ink',
        );
        expect(ink.calls, 1);
      },
    );
  });

  test('OCR labels an element whose label fused into its outline', () async {
    final list = ElementList(
      frames: [],
      elements: [
        SketchElement(
          id: 0,
          type: ElementType.btn,
          box: const Box(90, 40, 140, 45),
          strokes: const [0],
        ),
      ],
      arrows: [],
    );
    final reader = PhotoTextReader([
      const OcrWord('Sign', Box(110, 50, 50, 22)),
      const OcrWord('in', Box(165, 52, 30, 20)),
    ], _FakeReader());
    await readElementTexts(reader, list, {0: _stroke(90, 40, 140, 45)});
    expect(list.elements.single.text, 'Sign in');
  });

  test('FirstWorkingRecognizer falls through to the next option', () async {
    final chain = FirstWorkingRecognizer([
      _Failing(),
      const HeuristicStrokeRecognizer(),
    ]);
    final out = await chain.recognize(
      InkDocument(strokes: [_stroke(0, 0, 100, 0)]),
    );
    expect(out, isA<ElementList>());
    expect(chain.name, 'heuristic');
  });

  testWidgets(
    'photo -> canvas ink -> spec, and undo restores the drawn sketch',
    (tester) async {
      final photo = (await tester.runAsync(
        () async => importPhoto(await _sketchPng(), ocr: false),
      ))!;
      expect(photo.scale, 1.0); // 800 px long side: no downscale
      expect(photo.result.ink.strokes, isNotEmpty);
      expect(photo.result.ink.frames, isEmpty);

      final c = SketchController();
      c.loadPhoto(photo);
      expect(c.photo, same(photo));
      expect(c.doc.frames, isEmpty);
      expect(c.doc.strokes.length, photo.result.ink.strokes.length);

      final result = (await tester.runAsync(() => Pipeline().run(c.doc)))!;
      expect(result.spec.screens, isNotEmpty);
      expect(parseSpec(result.spec.toJson()).isValid, isTrue);

      c.undo();
      expect(c.photo, isNull);
      expect(
        c.doc.frames,
        hasLength(1),
      ); // the template frame from before the import
    },
  );
}
