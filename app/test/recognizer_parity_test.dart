// Python-vs-Dart parity for the learned recognizer's input features and output decoder.
// Fixtures are written by `python -m s2a.recognizer.export` (ml/s2a/recognizer/export.py).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sketch2app/ink/ink_model.dart';
import 'package:sketch2app/recognize/decode.dart';
import 'package:sketch2app/recognize/features.dart';

List<double> _flat(Object? nested) => switch (nested) {
  final List<Object?> l => [for (final x in l) ..._flat(x)],
  final num n => [n.toDouble()],
  _ => throw ArgumentError('$nested'),
};

void main() {
  final fixtures =
      Directory('test/fixtures/recognizer')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  test('fixtures exist', () => expect(fixtures, isNotEmpty));

  for (final f in fixtures) {
    final name = f.uri.pathSegments.last;
    final fx = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
    final doc = InkDocument.fromJson(fx['ink']! as Map<String, Object?>);

    test('$name: features match Python within 1e-4', () {
      final feats = inkFeatures(doc);
      final shape = _flat(fx['shape']);
      final geom = _flat(fx['geom']);
      expect(feats.shape.length, shape.length);
      expect(feats.geom.length, geom.length);
      var worst = 0.0;
      for (var i = 0; i < shape.length; i++) {
        worst = (feats.shape[i] - shape[i]).abs() > worst
            ? (feats.shape[i] - shape[i]).abs()
            : worst;
      }
      for (var i = 0; i < geom.length; i++) {
        worst = (feats.geom[i] - geom[i]).abs() > worst
            ? (feats.geom[i] - geom[i]).abs()
            : worst;
      }
      expect(worst, lessThan(1e-4));
    });

    test('$name: decoder matches Python', () {
      final out = decodeRecognizer(
        doc,
        _flat(fx['cls']),
        _flat(fx['type']),
        _flat(fx['affinity']),
      );
      final want = fx['decoded']! as Map<String, Object?>;
      final wantEls = want['elements']! as List<Object?>;
      expect(out.elements.length, wantEls.length);
      for (var k = 0; k < wantEls.length; k++) {
        final w = wantEls[k]! as Map<String, Object?>;
        final e = out.elements[k];
        expect(e.type.json, w['type']);
        expect(e.strokes, w['strokes']);
        expect(e.frame, w['frame']);
        expect(
          e.textStrokes,
          (w['text_strokes'] as List<Object?>?) ?? const <int>[],
        );
        final box = _flat(w['box']);
        expect(e.box.toJson(), [for (final v in box) closeTo(v, 1e-3)]);
        expect(e.score, closeTo((w['score']! as num).toDouble(), 1e-4));
      }
      final wantArrows = want['arrows']! as List<Object?>;
      expect(out.arrows.length, wantArrows.length);
      for (var k = 0; k < wantArrows.length; k++) {
        final w = wantArrows[k]! as Map<String, Object?>;
        expect(out.arrows[k].strokes, w['strokes']);
        expect(
          [out.arrows[k].tail.$1, out.arrows[k].tail.$2],
          [for (final v in _flat(w['tail'])) closeTo(v, 1e-3)],
        );
        expect(
          [out.arrows[k].head.$1, out.arrows[k].head.$2],
          [for (final v in _flat(w['head'])) closeTo(v, 1e-3)],
        );
      }
      expect(out.frames.length, (want['frames']! as List<Object?>).length);
    });
  }
}
