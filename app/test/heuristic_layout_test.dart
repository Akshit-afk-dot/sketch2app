import 'package:flutter_test/flutter_test.dart';
import 'package:sketch2app/layout/heuristic_layout.dart';
import 'package:sketch2app/recognize/elements.dart';
import 'package:sketch2app/recognize/heuristic_recognizer.dart';
import 'package:sketch2app/spec/spec.dart';

import 'package:sketch2app/ink/sketch_builder.dart';

/// Stands in for ML Kit: each word's strokes map to the string the test "wrote".
class _Words {
  final _byStroke = <int, String>{};
  void add(List<int> strokes, String text) => _byStroke[strokes.first] = text;

  void read(ElementList list) {
    for (final e in list.elements) {
      final hits = e.textStrokes.map((s) => _byStroke[s]).nonNulls.toList();
      if (hits.isNotEmpty) e.text = hits.join(' ');
    }
  }
}

AppSpec _pipeline(SketchBuilder b, _Words words) {
  final elements = const HeuristicRecognizer().recognize(b.doc);
  words.read(elements);
  final spec = const HeuristicLayoutBuilder().build(elements);
  final check = parseSpec(spec.toJson());
  expect(check.issues, isEmpty, reason: canonicalJson(spec));
  return spec;
}

void main() {
  test('definition-of-done sketch: login -> list, Sign in navigates', () {
    final b = SketchBuilder()
      ..frame(0, 0)
      ..frame(500, 0);
    final w = _Words();
    // Screen 1: login.
    b.imageBox(30, 40, 300, 150);
    w.add(b.word(30, 224, 5), 'Email');
    b.rect(30, 250, 300, 44);
    w.add(b.word(30, 314, 8), 'Password');
    b.rect(30, 340, 300, 44);
    b.rect(30, 420, 300, 48);
    w.add(b.word(42, 436, 7), 'Sign in');
    w.add(b.word(100, 500, 9), 'Forgot password?');
    b.arrow(330, 444, 560, 300);
    // Screen 2: list with app bar, one card item and "x5".
    w.add(b.word(620, 20, 5), 'Items');
    b.line(500, 60, 860, 60);
    b.rect(520, 100, 260, 120);
    b.imageBox(535, 112, 90, 90);
    w.add(b.word(640, 150, 4), 'Item');
    w.add(b.word(800, 150, 2, size: 14), 'x5');

    final spec = _pipeline(b, w);
    // No title on the login frame, so its id falls back to the screen number.
    expect(spec.screens.map((s) => s.id), ['screen_1', 'items']);
    final login = spec.screens.first;
    final c = (login.body as ColNode).c;
    expect(c.map((n) => n.type), ['img', 'input', 'input', 'btn', 'text']);
    expect((c[2] as InputNode).secure, isTrue, reason: 'label contains "pass"');
    expect((c[3] as ButtonNode).go, 'items');
    final list = spec.screens[1];
    expect(list.appbar?.title, 'Items');
    final body = list.body as ListNode;
    expect(body.n, 5);
    expect(body.item, isA<CardNode>());
  });

  test(
    'repeated identical rows become a list; identical cards in a row become a grid',
    () {
      final b = SketchBuilder()..frame(0, 0);
      final w = _Words();
      for (var k = 0; k < 3; k++) {
        b.rect(20, 40 + k * 90.0, 320, 70);
        b.imageBox(30, 50 + k * 90.0, 50, 50);
        w.add(b.word(100, 60 + k * 90.0, 4), 'Name');
      }
      for (var k = 0; k < 2; k++) {
        b.rect(20 + k * 170.0, 400, 150, 150);
        b.imageBox(30 + k * 170.0, 410, 130, 90);
        w.add(b.word(30 + k * 170.0, 515, 4), 'Shoe');
      }
      final spec = _pipeline(b, w);
      final c = (spec.screens.single.body as ColNode).c;
      expect(c.first, isA<ListNode>().having((l) => l.n, 'n', 3));
      expect(c.last, isA<GridNode>().having((g) => g.cols, 'cols', 2));
    },
  );

  test('stacked radios form one group; bottom nav gets one item per icon', () {
    final b = SketchBuilder()..frame(0, 0);
    final w = _Words();
    for (var k = 0; k < 3; k++) {
      b.ellipse(40, 100 + k * 40.0, 10, 10);
      w.add(b.word(60, 92 + k * 40.0, 4), ['Small', 'Medium', 'Large'][k]);
    }
    b.rect(0, 660, 360, 60);
    for (final x in [60.0, 180.0, 300.0]) {
      b.ellipse(x, 690, 10, 10);
    }
    final spec = _pipeline(b, w);
    final s = spec.screens.single;
    expect(
      (s.body as ColNode).c.single,
      isA<RadioNode>().having((r) => r.options, 'options', [
        'Small',
        'Medium',
        'Large',
      ]),
    );
    expect(s.bottomnav?.items.map((i) => i.label), [
      'Home',
      'Search',
      'Profile',
    ]);
  });

  test('empty canvas still yields a valid one-screen spec', () {
    final spec = const HeuristicLayoutBuilder().build(
      ElementList(frames: const [], elements: [], arrows: const []),
    );
    expect(parseSpec(spec.toJson()).isValid, isTrue);
  });
}
