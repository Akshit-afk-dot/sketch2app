/// Recognizer outputs -> element list: an exact port of ml/s2a/recognizer/decode.py.
///
/// Average-linkage clustering of the pairwise "same group" probabilities, then each cluster becomes a
/// frame, an arrow or an element (majority stroke class; element type = summed type probabilities).
library;

import 'dart:math' as math;

import '../ink/ink_model.dart';
import 'elements.dart';

const strokeClasses = ['frame', 'text', 'shape', 'arrow'];
const elementTypes = [
  'btn',
  'input',
  'text',
  'heading',
  'para',
  'img',
  'icon',
  'menu',
  'avatar',
  'check',
  'radio', //
  'switch', 'divider', 'card', 'appbar', 'bottomnav', 'fab', 'listmark',
];
const int _frame = 0, _text = 1, _arrow = 3;
const int noneType = 18;

List<double> _softmax(List<double> row) {
  final m = row.reduce(math.max);
  final e = [for (final v in row) math.exp(v - m)];
  final s = e.fold<double>(0, (a, b) => a + b);
  return [for (final v in e) v / s];
}

/// Average-linkage agglomerative clustering; [prob] is a symmetric n x n matrix (row-major).
List<List<int>> cluster(List<double> prob, int n, {double threshold = 0.5}) {
  final clusters = [
    for (var i = 0; i < n; i++) [i],
  ];
  final sums = List<double>.of(prob);
  final sizes = List<double>.filled(n, 1);
  final alive = List<bool>.filled(n, true);
  while (true) {
    var best = -double.infinity;
    var bi = -1, bj = -1;
    // Row-major scan keeping the first maximum, like numpy's argmax over the full matrix.
    for (var i = 0; i < n; i++) {
      if (!alive[i]) continue;
      for (var j = 0; j < n; j++) {
        if (j == i || !alive[j]) continue;
        final avg = sums[i * n + j] / (sizes[i] * sizes[j]);
        if (avg > best) {
          best = avg;
          bi = i;
          bj = j;
        }
      }
    }
    if (bi < 0 || best <= threshold) break;
    final i = math.min(bi, bj), j = math.max(bi, bj);
    clusters[i].addAll(clusters[j]);
    clusters[j] = [];
    for (var k = 0; k < n; k++) {
      sums[i * n + k] += sums[j * n + k];
    }
    for (var k = 0; k < n; k++) {
      sums[k * n + i] += sums[k * n + j];
    }
    sizes[i] += sizes[j];
    alive[j] = false;
  }
  return [
    for (final c in clusters)
      if (c.isNotEmpty) (c..sort()),
  ];
}

Box _box(Iterable<InkStroke> strokes) =>
    strokes.map((s) => s.box).reduce((a, b) => a.union(b));

double _len(InkStroke s) {
  var sum = 0.0;
  for (var k = 0; k + 1 < s.points.length; k++) {
    final dx = s.points[k + 1].x - s.points[k].x,
        dy = s.points[k + 1].y - s.points[k].y;
    sum += math.sqrt(dx * dx + dy * dy);
  }
  return sum;
}

/// Shaft = longest stroke; head = the shaft end nearest the other (head) strokes, else its last point.
((double, double), (double, double)) _arrowEnds(List<InkStroke> strokes) {
  var shaft = strokes.first;
  var best = -1.0;
  for (final s in strokes) {
    final l = _len(s);
    if (l > best) {
      best = l;
      shaft = s;
    }
  }
  var a = (shaft.points.first.x, shaft.points.first.y);
  var b = (shaft.points.last.x, shaft.points.last.y);
  final others = [
    for (final s in strokes)
      if (!identical(s, shaft)) ...s.points,
  ];
  if (others.isNotEmpty) {
    final cx = others.map((p) => p.x).reduce((x, y) => x + y) / others.length;
    final cy = others.map((p) => p.y).reduce((x, y) => x + y) / others.length;
    double d((double, double) p) =>
        math.sqrt(math.pow(p.$1 - cx, 2) + math.pow(p.$2 - cy, 2));
    if (d(a) < d(b)) (a, b) = (b, a);
  }
  return (a, b);
}

/// Logits are flattened row-major: cls (S x 4), type (S x 19), affinity (S x S).
ElementList decodeRecognizer(
  InkDocument doc,
  List<double> clsLogits,
  List<double> typeLogits,
  List<double> affLogits, {
  double threshold = 0.5,
}) {
  final n = doc.strokes.length;
  final clsP = [
    for (var i = 0; i < n; i++) _softmax(clsLogits.sublist(i * 4, i * 4 + 4)),
  ];
  final typeP = [
    for (var i = 0; i < n; i++)
      _softmax(typeLogits.sublist(i * 19, i * 19 + 19)),
  ];
  final prob = [for (final v in affLogits) 1 / (1 + math.exp(-v))];
  final groups = n == 0
      ? <List<int>>[]
      : cluster(prob, n, threshold: threshold);

  int argmax(List<double> v) {
    var k = 0;
    for (var i = 1; i < v.length; i++) {
      if (v[i] > v[k]) k = i;
    }
    return k;
  }

  List<double> sumRows(List<List<double>> rows, List<int> idx) {
    final out = List<double>.filled(rows.first.length, 0);
    for (final i in idx) {
      for (var k = 0; k < out.length; k++) {
        out[k] += rows[i][k];
      }
    }
    return out;
  }

  final frames = [...doc.frames];
  final elements = <SketchElement>[];
  final arrows = <SketchArrow>[];
  final pending = <(List<int>, int)>[];
  for (final g in groups) {
    final kind = argmax(sumRows(clsP, g));
    final strokes = [for (final i in g) doc.strokes[i]];
    if (kind == _frame) {
      frames.add(InkFrame(frames.length, _box(strokes)));
    } else if (kind == _arrow) {
      final (tail, head) = _arrowEnds(strokes);
      arrows.add(
        SketchArrow(id: arrows.length, tail: tail, head: head, strokes: g),
      );
    } else {
      final scores = sumRows(typeP, g);
      scores[noneType] = -1;
      pending.add((g, argmax(scores)));
    }
  }
  for (final (g, t) in pending) {
    final box = _box([for (final i in g) doc.strokes[i]]);
    int? frame;
    for (final f in frames) {
      if (f.box.containsPoint(box.cx, box.cy)) {
        frame = f.id;
        break;
      }
    }
    final score =
        g.map((i) => typeP[i].reduce(math.max)).reduce((a, b) => a + b) /
        g.length;
    elements.add(
      SketchElement(
        id: elements.length,
        type: ElementType.fromJson(elementTypes[t]),
        box: box,
        frame: frame,
        strokes: g,
        textStrokes: [
          for (final i in g)
            if (argmax(clsP[i]) == _text) i,
        ],
        score: score,
      ),
    );
  }
  return ElementList(frames: frames, elements: elements, arrows: arrows);
}
