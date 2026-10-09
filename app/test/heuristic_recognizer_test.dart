import 'package:flutter_test/flutter_test.dart';
import 'package:sketch2app/ink/ink_model.dart';
import 'package:sketch2app/recognize/elements.dart';
import 'package:sketch2app/recognize/geometry.dart';
import 'package:sketch2app/recognize/heuristic_recognizer.dart';

import 'package:sketch2app/ink/sketch_builder.dart';

List<String> _types(ElementList list, {int? frame}) => [
  for (final e in list.elements..sort((a, b) => a.box.y.compareTo(b.box.y)))
    if (frame == null || e.frame == frame) e.type.json,
];

void main() {
  const r = HeuristicRecognizer();

  group('primitives', () {
    Primitive classify(InkStroke s) => StrokeFeatures.of(s).classify();
    test('rect, ellipse, lines, wavy, scribble', () {
      final b = SketchBuilder()
        ..rect(0, 0, 100, 40)
        ..ellipse(50, 50, 20, 20)
        ..line(0, 0, 200, 2)
        ..line(0, 0, 2, 200)
        ..line(0, 0, 100, 100)
        ..wavy(0, 0, 200)
        ..word(0, 0, 1);
      expect(b.strokes.map(classify).toList(), [
        Primitive.rect,
        Primitive.ellipse,
        Primitive.hline,
        Primitive.vline,
        Primitive.diag,
        Primitive.wavy,
        Primitive.scribble,
      ]);
    });
  });

  test('login screen: image, two inputs, button, link text', () {
    final b = SketchBuilder()..frame(0, 0);
    b.imageBox(30, 40, 300, 150);
    b.input(30, 250, 300, 44, 5);
    b.input(30, 340, 300, 44, 8);
    b.button(30, 420, 300, 48, 7);
    b.word(100, 500, 9);
    final out = r.recognize(b.doc);
    expect(_types(out), ['img', 'input', 'input', 'btn', 'text']);
    final btn = out.elements.firstWhere((e) => e.type == ElementType.btn);
    expect(btn.textStrokes, hasLength(7));
    final input = out.elements.firstWhere((e) => e.type == ElementType.input);
    expect(
      input.textStrokes,
      hasLength(5),
      reason: 'label above the box belongs to the input',
    );
  });

  test('drawn frame is detected and owns no element', () {
    final b = SketchBuilder()..drawnFrame(0, 0);
    b.button(30, 100, 300, 48, 4);
    b.word(30, 200, 6);
    b.imageBox(30, 300, 300, 150);
    final out = r.recognize(b.doc);
    expect(out.frames, hasLength(1));
    expect(out.frames.single.box.h, closeTo(720, 1));
    expect(_types(out), ['btn', 'text', 'img']);
  });

  test('two frames and an arrow from a button to the second frame', () {
    final b = SketchBuilder()
      ..frame(0, 0)
      ..frame(500, 0);
    b.button(30, 400, 300, 48, 7);
    b.word(530, 100, 4);
    b.arrow(330, 424, 560, 300);
    final out = r.recognize(b.doc);
    expect(out.arrows, hasLength(1));
    final a = out.arrows.single;
    expect(a.tail.$1, closeTo(330, 1));
    expect(a.head.$1, closeTo(560, 1));
    expect(a.strokes, hasLength(3), reason: 'shaft + two head strokes');
    expect(_types(out, frame: 0), ['btn']);
    expect(_types(out, frame: 1), ['text']);
  });

  test(
    'controls: checkbox, radio, switch, avatar, divider, heading, paragraph, menu',
    () {
      final b = SketchBuilder()..frame(0, 0);
      b.line(20, 40, 40, 40); // menu: three short lines
      b.line(20, 48, 40, 48);
      b.line(20, 56, 40, 56);
      b.word(30, 90, 6);
      b.line(30, 112, 130, 112); // heading underline
      b.ellipse(60, 180, 35, 35);
      b.ellipse(60, 175, 12, 12); // avatar
      b.rect(30, 250, 20, 20);
      b.word(60, 252, 5); // checkbox
      b.ellipse(40, 300, 10, 10);
      b.word(60, 292, 4); // radio
      b.word(30, 340, 5);
      b.rect(200, 338, 60, 26);
      b.ellipse(215, 351, 9, 9); // switch with label on the left
      b.line(20, 400, 340, 401); // divider
      b.wavy(30, 440, 280);
      b.wavy(30, 460, 250); // paragraph
      final out = r.recognize(b.doc);
      expect(_types(out).toSet(), {
        'menu',
        'heading',
        'avatar',
        'check',
        'radio',
        'switch',
        'divider',
        'para',
      });
      expect(
        out.elements.where((e) => e.type == ElementType.para).single.strokes,
        hasLength(2),
      );
    },
  );

  test('appbar and bottom nav bands, fab with plus', () {
    final b = SketchBuilder()..frame(0, 0);
    b.line(0, 60, 360, 60); // appbar band drawn as a line under the title
    b.word(120, 20, 5);
    b.button(30, 200, 300, 48, 3);
    b.ellipse(300, 600, 22, 22); // fab
    b.line(290, 600, 310, 600);
    b.line(300, 590, 300, 610);
    b.rect(0, 660, 360, 60); // bottom nav band
    b.ellipse(60, 690, 10, 10);
    b.ellipse(180, 690, 10, 10);
    b.ellipse(300, 690, 10, 10);
    final out = r.recognize(b.doc);
    final types = _types(out);
    expect(types.first, 'appbar');
    expect(
      out.elements.firstWhere((e) => e.type == ElementType.appbar).textStrokes,
      hasLength(5),
    );
    expect(types, containsAll(['btn', 'fab', 'bottomnav']));
    expect(
      types.where((t) => t == 'icon'),
      hasLength(3),
      reason: 'nav icons stay separate elements',
    );
  });

  test('card containing an image and text', () {
    final b = SketchBuilder()..frame(0, 0);
    b.rect(20, 100, 320, 200);
    b.imageBox(40, 120, 120, 100);
    b.word(180, 140, 5);
    b.word(180, 180, 3);
    final out = r.recognize(b.doc);
    expect(_types(out), ['card', 'img', 'text', 'text']);
  });

  test('every stroke is owned by at most one element', () {
    final b = SketchBuilder()..frame(0, 0);
    b.imageBox(30, 40, 300, 150);
    b.button(30, 420, 300, 48, 7);
    b.input(30, 250, 300, 44, 5);
    final out = r.recognize(b.doc);
    final owned = [for (final e in out.elements) ...e.strokes];
    expect(owned.toSet().length, owned.length);
    expect(owned.toSet(), b.strokes.map((s) => s.id).toSet());
  });
}
