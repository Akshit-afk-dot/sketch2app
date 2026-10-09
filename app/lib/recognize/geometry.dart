/// Per-stroke geometric features and a rule-based primitive classifier.
///
/// These are the same kinds of features the learned recognizer receives (bbox, length, closedness,
/// straightness, corners), so the heuristic baseline and the model compete on equal information.
library;

import 'dart:math' as math;

import '../ink/ink_model.dart';

enum Primitive { rect, ellipse, hline, vline, diag, wavy, scribble }

class StrokeFeatures {
  StrokeFeatures._(
    this.stroke,
    this.box,
    this.length,
    this.closure,
    this.straightness,
    this.corners,
    this.areaRatio,
    this.yTurns,
  );

  factory StrokeFeatures.of(InkStroke s) {
    final pts = s.points;
    final box = s.box;
    final length = s.length;
    final diag = math.max(box.diagonal, 1e-6);
    final first = pts.first, last = pts.last;
    final endGap = _d(first.x, first.y, last.x, last.y);
    final closure = endGap / diag;
    final straightness = length <= 1e-6 ? 1.0 : endGap / length;
    final simplified = rdp(pts.map((p) => (p.x, p.y)).toList(), 0.06 * diag);
    final corners = math.max(0, simplified.length - 2);
    final areaRatio = _shoelace(pts).abs() / math.max(box.area, 1e-6);
    return StrokeFeatures._(
      s,
      box,
      length,
      closure,
      straightness,
      corners,
      areaRatio,
      _yTurns(pts, box.h),
    );
  }

  final InkStroke stroke;
  final Box box;
  final double length;

  /// Distance between first and last point relative to the bbox diagonal (0 = perfectly closed).
  final double closure;

  /// Endpoint distance over path length (1 = straight line).
  final double straightness;

  /// Interior vertices left after Ramer-Douglas-Peucker simplification.
  final int corners;

  /// Enclosed area over bbox area: ~1.0 for a rectangle, pi/4 = 0.785 for any ellipse (aspect-invariant).
  final double areaRatio;

  /// Direction changes in y (wavy lines have several, straight lines none).
  final int yTurns;

  Primitive classify() {
    final isClosed = closure < 0.25 && length > 0.5 * (box.w + box.h);
    if (isClosed) {
      if (areaRatio > 0.88) return Primitive.rect;
      if (areaRatio > 0.6) return Primitive.ellipse;
    }
    // Wavy before straight: a paragraph squiggle is nearly straight end-to-end. Requiring visible
    // amplitude (h > 2% of w) and counting only swings of >= 40% of that height keeps jittery straight
    // lines out.
    if (box.w > 3 * box.h &&
        box.h > 0.02 * box.w &&
        yTurns >= 3 &&
        length < 2.5 * box.w) {
      return Primitive.wavy;
    }
    if (straightness > 0.9) {
      final angle = math.atan2(box.h, math.max(box.w, 1e-6)) * 180 / math.pi;
      if (angle < 15) return Primitive.hline;
      if (angle > 75) return Primitive.vline;
      return Primitive.diag;
    }
    return Primitive.scribble;
  }
}

double _d(double ax, double ay, double bx, double by) =>
    math.sqrt((ax - bx) * (ax - bx) + (ay - by) * (ay - by));

double _shoelace(List<InkPoint> pts) {
  var s = 0.0;
  for (var i = 0; i < pts.length; i++) {
    final a = pts[i], b = pts[(i + 1) % pts.length];
    s += a.x * b.y - b.x * a.y;
  }
  return s / 2;
}

/// Counts sign changes of dy, ignoring swings smaller than 40% of the stroke height (jitter).
int _yTurns(List<InkPoint> pts, double h) {
  final tol = math.max(0.4 * h, 0.5);
  var turns = 0;
  var dir = 0;
  var anchor = pts.first.y;
  for (final p in pts.skip(1)) {
    final dy = p.y - anchor;
    if (dy.abs() < tol) continue;
    final d = dy > 0 ? 1 : -1;
    if (dir != 0 && d != dir) turns++;
    dir = d;
    anchor = p.y;
  }
  return turns;
}

/// Ramer-Douglas-Peucker polyline simplification.
List<(double, double)> rdp(List<(double, double)> pts, double eps) {
  if (pts.length < 3) return pts;
  final (ax, ay) = pts.first;
  final (bx, by) = pts.last;
  var maxD = -1.0;
  var idx = 0;
  for (var i = 1; i < pts.length - 1; i++) {
    final d = _pointSegment(pts[i].$1, pts[i].$2, ax, ay, bx, by);
    if (d > maxD) {
      maxD = d;
      idx = i;
    }
  }
  if (maxD <= eps) return [pts.first, pts.last];
  final left = rdp(pts.sublist(0, idx + 1), eps);
  final right = rdp(pts.sublist(idx), eps);
  return [...left.sublist(0, left.length - 1), ...right];
}

double _pointSegment(
  double px,
  double py,
  double ax,
  double ay,
  double bx,
  double by,
) {
  final dx = bx - ax, dy = by - ay;
  final len2 = dx * dx + dy * dy;
  if (len2 == 0) return _d(px, py, ax, ay);
  final t = (((px - ax) * dx + (py - ay) * dy) / len2).clamp(0.0, 1.0);
  return _d(px, py, ax + t * dx, ay + t * dy);
}
