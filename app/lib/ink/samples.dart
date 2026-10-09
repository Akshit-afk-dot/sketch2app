/// Built-in sample sketches, drawn programmatically per the legend. They let the demo run even if
/// nobody draws, and give device tests a reproducible input.
library;

import 'ink_model.dart';
import 'sketch_builder.dart';

class SampleSketch {
  const SampleSketch(this.name, this.build);
  final String name;
  final InkDocument Function() build;
}

const sampleSketches = [
  SampleSketch('Login -> list (2 screens)', _loginList),
  SampleSketch('Settings', _settings),
];

InkDocument _loginList() {
  final b = SketchBuilder()
    ..frame(0, 0, 360, 760)
    ..frame(480, 0, 360, 760);
  b.imageBox(30, 50, 300, 150);
  b.input(30, 270, 300, 44, 5);
  b.input(30, 360, 300, 44, 8);
  b.button(30, 440, 300, 50, 7);
  b.word(100, 520, 9);
  b.arrow(330, 465, 540, 300);
  b.word(600, 22, 5);
  b.line(480, 64, 840, 64);
  b.rect(500, 100, 250, 120);
  b.imageBox(515, 112, 90, 90);
  b.word(620, 150, 4);
  b.word(775, 150, 2, size: 14);
  return b.doc;
}

InkDocument _settings() {
  final b = SketchBuilder()..frame(0, 0, 360, 760);
  b.word(110, 22, 8);
  b.line(0, 64, 360, 64);
  for (var k = 0; k < 2; k++) {
    final y = 110 + k * 60.0;
    b.word(30, y, 7);
    b.rect(260, y, 60, 26);
    b.ellipse(275, y + 13, 9, 9);
  }
  b.line(20, 240, 340, 241);
  for (var k = 0; k < 3; k++) {
    b.ellipse(40, 290 + k * 40.0, 10, 10);
    b.word(60, 282 + k * 40.0, 5);
  }
  b.button(30, 450, 300, 50, 6);
  return b.doc;
}
