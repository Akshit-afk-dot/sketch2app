/// Draws clean legend shapes as ink: cheat-sheet pictures, bundled sample sketches and unit tests.
/// Noisy, human-like sketches for training come from the Python synthetic generator (P3).
library;

import 'dart:math' as math;

import 'ink_model.dart';

class SketchBuilder {
  final strokes = <InkStroke>[];
  final frames = <InkFrame>[];
  var _t = 0;

  InkDocument get doc => InkDocument(strokes: strokes, frames: frames);

  int _add(List<(double, double)> pts) {
    final id = strokes.length;
    strokes.add(
      InkStroke(id, [for (final (x, y) in pts) InkPoint(x, y, _t += 8)]),
    );
    _t += 200;
    return id;
  }

  List<(double, double)> _segment(
    double x0,
    double y0,
    double x1,
    double y1, [
    int n = 12,
  ]) => [
    for (var i = 0; i <= n; i++)
      (x0 + (x1 - x0) * i / n, y0 + (y1 - y0) * i / n),
  ];

  /// Template frame placed with the "New screen" button.
  void frame(double x, double y, [double w = 360, double h = 720]) =>
      frames.add(InkFrame(frames.length, Box(x, y, w, h)));

  /// Hand-drawn frame (a big rectangle stroke).
  int drawnFrame(double x, double y, [double w = 360, double h = 720]) =>
      rect(x, y, w, h);

  int rect(double x, double y, double w, double h) => _add([
    ..._segment(x, y, x + w, y),
    ..._segment(x + w, y, x + w, y + h).skip(1),
    ..._segment(x + w, y + h, x, y + h).skip(1),
    ..._segment(x, y + h, x, y).skip(1),
  ]);

  int ellipse(double cx, double cy, double rx, double ry) => _add([
    for (var i = 0; i <= 40; i++)
      (
        cx + rx * math.cos(2 * math.pi * i / 40),
        cy + ry * math.sin(2 * math.pi * i / 40),
      ),
  ]);

  int line(double x0, double y0, double x1, double y1) =>
      _add(_segment(x0, y0, x1, y1));

  int wavy(double x, double y, double w, {double amp = 3}) => _add([
    for (var i = 0; i <= 60; i++)
      (x + w * i / 60, y + amp * math.sin(i / 60 * w / 8)),
  ]);

  /// A handwritten word: one small zigzag scribble per letter, letters ~[size] tall.
  List<int> word(double x, double y, int letters, {double size = 16}) => [
    for (var k = 0; k < letters; k++)
      _add([
        for (var i = 0; i <= 8; i++)
          (
            x + k * size * 0.7 + size * 0.5 * i / 8,
            y + (i.isEven ? 0 : size) + (i % 4 == 1 ? size * 0.2 : 0),
          ),
      ]),
  ];

  void imageBox(double x, double y, double w, double h) {
    rect(x, y, w, h);
    line(x, y, x + w, y + h);
    line(x + w, y, x, y + h);
  }

  void button(double x, double y, double w, double h, int letters) {
    rect(x, y, w, h);
    word(x + 12, y + h / 2 - 8, letters);
  }

  void input(double x, double y, double w, double h, int labelLetters) {
    word(x, y - 26, labelLetters);
    rect(x, y, w, h);
  }

  /// Arrow drawn as one shaft stroke plus two head strokes.
  void arrow(double x0, double y0, double x1, double y1) {
    line(x0, y0, x1, y1);
    final a = math.atan2(y1 - y0, x1 - x0);
    for (final s in [-1, 1]) {
      line(
        x1,
        y1,
        x1 - 14 * math.cos(a + s * 0.5),
        y1 - 14 * math.sin(a + s * 0.5),
      );
    }
  }
}
