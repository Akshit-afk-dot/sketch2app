import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sketch2app/ink/ink_model.dart';
import 'package:sketch2app/photo/vectorize.dart';

/// A synthetic "photo": paper of brightness [paper] (optionally a left-to-right lighting ramp), optional
/// dark table around an inset sheet, and thick dark pen lines.
class _Photo {
  _Photo(this.w, this.h, {int paper = 230, int ramp = 0, int tableInset = 0})
    : px = Uint8List(w * h) {
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final onPaper =
            x >= tableInset &&
            y >= tableInset &&
            x < w - tableInset &&
            y < h - tableInset;
        px[y * w + x] = onPaper ? paper - ramp * (w - x) ~/ w : 60;
      }
    }
  }

  final int w;
  final int h;
  final Uint8List px;

  /// Pen line of the given thickness; ink is 60% darker than the paper under it.
  void line(double x0, double y0, double x1, double y1, {double width = 4}) {
    final r = width / 2;
    final l = (math.min(x0, x1) - r).floor(),
        t = (math.min(y0, y1) - r).floor();
    final rr = (math.max(x0, x1) + r).ceil(), b = (math.max(y0, y1) + r).ceil();
    for (var y = math.max(0, t); y <= math.min(h - 1, b); y++) {
      for (var x = math.max(0, l); x <= math.min(w - 1, rr); x++) {
        if (_segDist(x.toDouble(), y.toDouble(), x0, y0, x1, y1) <= r) {
          px[y * w + x] = (px[y * w + x] * 0.4).round();
        }
      }
    }
  }

  void rect(double x, double y, double rw, double rh) {
    line(x, y, x + rw, y);
    line(x + rw, y, x + rw, y + rh);
    line(x + rw, y + rh, x, y + rh);
    line(x, y + rh, x, y);
  }

  VectorizeResult run() => vectorize(GrayImage(w, h, px));
}

double _segDist(
  double px,
  double py,
  double ax,
  double ay,
  double bx,
  double by,
) {
  final dx = bx - ax, dy = by - ay;
  final len2 = dx * dx + dy * dy;
  final t = len2 == 0
      ? 0.0
      : (((px - ax) * dx + (py - ay) * dy) / len2).clamp(0.0, 1.0);
  final cx = ax + t * dx - px, cy = ay + t * dy - py;
  return math.sqrt(cx * cx + cy * cy);
}

double _len(InkStroke s) {
  var d = 0.0;
  for (var k = 1; k < s.points.length; k++) {
    d += math.sqrt(
      math.pow(s.points[k].x - s.points[k - 1].x, 2) +
          math.pow(s.points[k].y - s.points[k - 1].y, 2),
    );
  }
  return d;
}

void main() {
  test('a rectangle outline becomes one closed stroke with the same box', () {
    final p = _Photo(400, 300)..rect(100, 80, 200, 140);
    final strokes = p.run().ink.strokes;
    expect(strokes, hasLength(1));
    final s = strokes.single;
    final box = s.box;
    expect(box.x, closeTo(100, 4));
    expect(box.y, closeTo(80, 4));
    expect(box.w, closeTo(200, 6));
    expect(box.h, closeTo(140, 6));
    final first = s.points.first, last = s.points.last;
    expect((first.x - last.x).abs() + (first.y - last.y).abs(), lessThan(6));
  });

  test('two crossing lines stay two straight strokes', () {
    final p = _Photo(400, 300)
      ..line(60, 150, 340, 150)
      ..line(200, 40, 200, 260);
    final strokes = p.run().ink.strokes;
    expect(strokes, hasLength(2));
    final lengths = strokes.map(_len).toList()..sort();
    expect(lengths[0], closeTo(220, 12));
    expect(lengths[1], closeTo(280, 12));
  });

  test('a T junction: the bar continues, the stem ends at it', () {
    final p = _Photo(400, 300)
      ..line(60, 80, 340, 80)
      ..line(200, 80, 200, 260);
    final strokes = p.run().ink.strokes;
    expect(strokes, hasLength(2));
    final lengths = strokes.map(_len).toList()..sort();
    expect(lengths[1], closeTo(280, 12));
    expect(lengths[0], closeTo(180, 12));
  });

  test('specks are dropped and a dot-sized mark survives', () {
    final p = _Photo(400, 300)..line(50, 50, 300, 50);
    for (final (x, y) in [(100, 200), (250, 120), (330, 260)]) {
      p.px[y * 400 + x] = 20; // single-pixel noise
    }
    p.line(200, 200, 200.5, 200, width: 5); // i-dot
    final strokes = p.run().ink.strokes;
    expect(strokes, hasLength(2));
    expect(strokes.map(_len).reduce(math.min), lessThan(4));
  });

  test('the edge of the sheet on a dark table is not a stroke', () {
    final p = _Photo(400, 300, tableInset: 30)..line(80, 150, 320, 150);
    final r = p.run();
    expect(r.ink.strokes, hasLength(1));
    expect(r.page.x, greaterThanOrEqualTo(30));
    expect(r.page.y, greaterThanOrEqualTo(30));
  });

  test('uneven lighting does not create or lose strokes', () {
    final p = _Photo(400, 300, paper: 245, ramp: 110)
      ..line(30, 100, 370, 100)
      ..line(30, 200, 370, 200);
    final strokes = p.run().ink.strokes;
    expect(strokes, hasLength(2));
    for (final s in strokes) {
      expect(_len(s), closeTo(340, 12));
    }
  });

  test('strokes come in reading order with non-decreasing time', () {
    final p = _Photo(400, 300)
      ..line(50, 200, 150, 200)
      ..line(250, 60, 350, 60)
      ..line(50, 60, 150, 60);
    final strokes = p.run().ink.strokes;
    expect(strokes, hasLength(3));
    expect([for (final s in strokes) s.box.y < 100], [true, true, false]);
    expect(strokes[0].box.x, lessThan(strokes[1].box.x));
    var t = -1;
    for (final s in strokes) {
      for (final q in s.points) {
        expect(q.t, greaterThanOrEqualTo(t));
        t = q.t;
      }
    }
  });

  test('vectorizing is deterministic', () {
    String once() => jsonEncode(
      (_Photo(400, 300)
            ..rect(40, 40, 120, 200)
            ..line(200, 60, 360, 240))
          .run()
          .ink
          .toJson(),
    );
    expect(once(), once());
  });

  test('fitWithin area-averages down to the long side and never upscales', () {
    final img = GrayImage(
      2560,
      1280,
      Uint8List(2560 * 1280)..fillRange(0, 2560 * 1280, 200),
    );
    final small = img.fitWithin(photoLongSide);
    expect((small.width, small.height), (1280, 640));
    expect(small.pixels.every((v) => v == 200), isTrue);
    expect(identical(small.fitWithin(photoLongSide), small), isTrue);
  });
}
