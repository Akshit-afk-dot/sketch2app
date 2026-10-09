/// Ink document model (spec/schema/ink.v1.schema.json). Pure Dart so recognizers and tools can use it.
library;

import 'dart:math' as math;

/// Axis-aligned box in canvas coordinates. Our own type (not dart:ui Rect) keeps this library
/// Flutter-free and mirrors the `[x, y, w, h]` arrays used in the JSON contracts.
class Box {
  const Box(this.x, this.y, this.w, this.h);

  factory Box.fromLTRB(double l, double t, double r, double b) =>
      Box(l, t, r - l, b - t);

  factory Box.fromJson(List<Object?> j) => Box(
    (j[0]! as num).toDouble(),
    (j[1]! as num).toDouble(),
    (j[2]! as num).toDouble(),
    (j[3]! as num).toDouble(),
  );

  final double x;
  final double y;
  final double w;
  final double h;

  double get right => x + w;
  double get bottom => y + h;
  double get cx => x + w / 2;
  double get cy => y + h / 2;
  double get area => w * h;
  double get diagonal => math.sqrt(w * w + h * h);

  Box union(Box o) => Box.fromLTRB(
    math.min(x, o.x),
    math.min(y, o.y),
    math.max(right, o.right),
    math.max(bottom, o.bottom),
  );

  Box? intersect(Box o) {
    final l = math.max(x, o.x),
        t = math.max(y, o.y),
        r = math.min(right, o.right),
        b = math.min(bottom, o.bottom);
    return r > l && b > t ? Box.fromLTRB(l, t, r, b) : null;
  }

  double iou(Box o) {
    final i = intersect(o)?.area ?? 0;
    final u = area + o.area - i;
    return u <= 0 ? 0 : i / u;
  }

  /// Fraction of this box covered by [o]. A degenerate box (a perfectly straight line) counts as covered
  /// when both of its ends are inside [o].
  double coveredBy(Box o) {
    if (w <= 0 || h <= 0) {
      return o.containsPoint(x, y) && o.containsPoint(right, bottom) ? 1 : 0;
    }
    return (intersect(o)?.area ?? 0) / area;
  }

  bool containsPoint(double px, double py) =>
      px >= x && px <= right && py >= y && py <= bottom;

  Box inflate(double d) => Box(x - d, y - d, w + 2 * d, h + 2 * d);

  List<double> toJson() => [x, y, w, h];

  @override
  String toString() =>
      'Box(${x.toStringAsFixed(1)}, ${y.toStringAsFixed(1)}, ${w.toStringAsFixed(1)}, ${h.toStringAsFixed(1)})';
}

class InkPoint {
  const InkPoint(this.x, this.y, this.t);
  final double x;
  final double y;

  /// Milliseconds since the document started.
  final int t;

  List<num> toJson() => [x, y, t];
}

enum InkTool { pen, touch, mouse }

class InkStroke {
  InkStroke(this.id, this.points, {this.tool = InkTool.touch});

  factory InkStroke.fromJson(Map<String, Object?> j) => InkStroke(
    j['id']! as int,
    [
      for (final p in j['pts']! as List<Object?>)
        if (p case [final num x, final num y, final num t])
          InkPoint(x.toDouble(), y.toDouble(), t.toInt()),
    ],
    tool: InkTool.values.firstWhere(
      (t) => t.name == j['tool'],
      orElse: () => InkTool.touch,
    ),
  );

  final int id;
  final List<InkPoint> points;
  final InkTool tool;

  Box get box {
    var l = double.infinity,
        t = double.infinity,
        r = -double.infinity,
        b = -double.infinity;
    for (final p in points) {
      l = math.min(l, p.x);
      t = math.min(t, p.y);
      r = math.max(r, p.x);
      b = math.max(b, p.y);
    }
    return Box.fromLTRB(l, t, r, b);
  }

  double get length {
    var sum = 0.0;
    for (var i = 1; i < points.length; i++) {
      sum += _dist(points[i - 1], points[i]);
    }
    return sum;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'tool': tool.name,
    'pts': [for (final p in points) p.toJson()],
  };
}

double _dist(InkPoint a, InkPoint b) =>
    math.sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));

class InkFrame {
  const InkFrame(this.id, this.box);

  factory InkFrame.fromJson(Map<String, Object?> j) =>
      InkFrame(j['id']! as int, Box.fromJson(j['box']! as List<Object?>));

  final int id;
  final Box box;
  Map<String, Object?> toJson() => {'id': id, 'box': box.toJson()};
}

class InkDocument {
  InkDocument({List<InkStroke>? strokes, List<InkFrame>? frames})
    : strokes = strokes ?? [],
      frames = frames ?? [];

  factory InkDocument.fromJson(Map<String, Object?> j) => InkDocument(
    strokes: [
      for (final s in j['strokes']! as List<Object?>)
        InkStroke.fromJson(s! as Map<String, Object?>),
    ],
    frames: [
      for (final f in (j['frames'] as List<Object?>?) ?? const [])
        InkFrame.fromJson(f! as Map<String, Object?>),
    ],
  );

  final List<InkStroke> strokes;
  final List<InkFrame> frames;

  int get nextStrokeId =>
      strokes.isEmpty ? 0 : strokes.map((s) => s.id).reduce(math.max) + 1;
  int get nextFrameId =>
      frames.isEmpty ? 0 : frames.map((f) => f.id).reduce(math.max) + 1;

  Map<String, Object?> toJson() => {
    'v': 1,
    'strokes': [for (final s in strokes) s.toJson()],
    'frames': [for (final f in frames) f.toJson()],
  };
}
