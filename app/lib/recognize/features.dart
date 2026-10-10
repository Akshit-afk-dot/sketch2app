/// Stroke features for the learned recognizer: an exact port of ml/s2a/recognizer/features.py.
///
/// Must match Python to ~1e-5 (checked by test/recognizer_parity_test.dart against fixtures written by
/// `python -m s2a.recognizer.export`), otherwise the model sees different inputs on the phone.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../ink/ink_model.dart';

const int resampleN = 32;
const int geomDim = 16;

/// Flattened features of one sketch: shape is (S, 32, 4) row-major, geom is (S, 16).
class StrokeFeatures {
  const StrokeFeatures(this.count, this.shape, this.geom);
  final int count;
  final Float32List shape;
  final Float32List geom;
}

/// (originX, originY, unit): template frames define the scale; otherwise ink height / 2.
(double, double, double) sampleUnit(InkDocument doc) {
  if (doc.frames.isNotEmpty) {
    final x0 = doc.frames.map((f) => f.box.x).reduce(math.min);
    final y0 = doc.frames.map((f) => f.box.y).reduce(math.min);
    final hs = doc.frames.map((f) => f.box.h).toList()..sort();
    final mid = hs.length ~/ 2;
    final median = hs.length.isOdd ? hs[mid] : (hs[mid - 1] + hs[mid]) / 2;
    return (x0, y0, math.max(median / 2, 1e-3));
  }
  var x0 = double.infinity, y0 = double.infinity, y1 = -double.infinity;
  for (final s in doc.strokes) {
    for (final p in s.points) {
      x0 = math.min(x0, p.x);
      y0 = math.min(y0, p.y);
      y1 = math.max(y1, p.y);
    }
  }
  return (x0, y0, math.max((y1 - y0) / 2, 1e-3));
}

/// 32 points equally spaced along the polyline; exact repeated points are dropped first (np.interp).
List<(double, double)> resample(List<InkPoint> raw) {
  final pts = <(double, double)>[(raw.first.x, raw.first.y)];
  for (final p in raw.skip(1)) {
    if (p.x != pts.last.$1 || p.y != pts.last.$2) pts.add((p.x, p.y));
  }
  if (pts.length == 1) return List.filled(resampleN, pts.first);
  final cum = <double>[0];
  for (var i = 1; i < pts.length; i++) {
    final dx = pts[i].$1 - pts[i - 1].$1, dy = pts[i].$2 - pts[i - 1].$2;
    cum.add(cum.last + math.sqrt(dx * dx + dy * dy));
  }
  final total = cum.last;
  final step = total / (resampleN - 1);
  final out = <(double, double)>[];
  var j = 0;
  for (var i = 0; i < resampleN; i++) {
    final t = i == resampleN - 1 ? total : step * i;
    while (j < cum.length - 2 && cum[j + 1] < t) {
      j++;
    }
    final span = cum[j + 1] - cum[j];
    final a = span <= 0 ? 0.0 : ((t - cum[j]) / span).clamp(0.0, 1.0);
    out.add((
      pts[j].$1 + a * (pts[j + 1].$1 - pts[j].$1),
      pts[j].$2 + a * (pts[j + 1].$2 - pts[j].$2),
    ));
  }
  return out;
}

double _log1p(double x) => math.log(1 + x);

StrokeFeatures inkFeatures(InkDocument doc) {
  final strokes = doc.strokes;
  final n = strokes.length;
  final shape = Float32List(n * resampleN * 4);
  final geom = Float32List(n * geomDim);
  if (n == 0) return StrokeFeatures(0, shape, geom);
  final (ox, oy, unit) = sampleUnit(doc);
  final t0 = strokes.first.points.first.t.toDouble();
  double? prevEnd;
  for (var s = 0; s < n; s++) {
    final pts = strokes[s].points;
    final r = resample(pts);
    var rx0 = double.infinity,
        ry0 = double.infinity,
        rx1 = -double.infinity,
        ry1 = -double.infinity;
    for (final (x, y) in r) {
      rx0 = math.min(rx0, x);
      ry0 = math.min(ry0, y);
      rx1 = math.max(rx1, x);
      ry1 = math.max(ry1, y);
    }
    final cx = (rx0 + rx1) / 2, cy = (ry0 + ry1) / 2;
    var half = math.max(rx1 - rx0, ry1 - ry0) / 2;
    if (half <= 1e-6) half = 1.0;
    final base = s * resampleN * 4;
    for (var i = 0; i < resampleN; i++) {
      final (x, y) = r[i];
      shape[base + i * 4] = (x - cx) / half;
      shape[base + i * 4 + 1] = (y - cy) / half;
      final k = i < resampleN - 1
          ? i
          : resampleN - 2; // last direction repeats the previous one
      final dx = r[k + 1].$1 - r[k].$1, dy = r[k + 1].$2 - r[k].$2;
      final norm = math.sqrt(dx * dx + dy * dy);
      shape[base + i * 4 + 2] = norm > 1e-9 ? dx / norm : 0;
      shape[base + i * 4 + 3] = norm > 1e-9 ? dy / norm : 0;
    }

    var x0 = double.infinity,
        y0 = double.infinity,
        x1 = -double.infinity,
        y1 = -double.infinity;
    var length = 0.0;
    for (var i = 0; i < pts.length; i++) {
      final p = pts[i];
      x0 = math.min(x0, p.x);
      y0 = math.min(y0, p.y);
      x1 = math.max(x1, p.x);
      y1 = math.max(y1, p.y);
      if (i > 0) {
        final dx = p.x - pts[i - 1].x, dy = p.y - pts[i - 1].y;
        length += math.sqrt(dx * dx + dy * dy);
      }
    }
    final w = x1 - x0, h = y1 - y0;
    final diag = math.sqrt(w * w + h * h);
    final gx = pts.first.x - pts.last.x, gy = pts.first.y - pts.last.y;
    final gap = math.sqrt(gx * gx + gy * gy);
    final duration = (pts.last.t - pts.first.t).toDouble();
    final pause = prevEnd == null ? 0.0 : pts.first.t - prevEnd;
    final g = s * geomDim;
    geom[g] = (x0 + w / 2 - ox) / unit;
    geom[g + 1] = (y0 + h / 2 - oy) / unit;
    geom[g + 2] = w / unit;
    geom[g + 3] = h / unit;
    geom[g + 4] = _log1p(length / unit * 10);
    geom[g + 5] = diag > 1e-6 ? gap / diag : 0;
    geom[g + 6] = length > 1e-6 ? gap / length : 1;
    geom[g + 7] = _log1p(pts.length.toDouble()) / 6;
    geom[g + 8] = _log1p(math.max(duration, 0) / 100);
    geom[g + 9] = _log1p(math.max(pause, 0) / 100);
    geom[g + 10] = (pts.first.t - t0) / 60000.0;
    geom[g + 11] = (pts.first.x - ox) / unit;
    geom[g + 12] = (pts.first.y - oy) / unit;
    geom[g + 13] = (pts.last.x - ox) / unit;
    geom[g + 14] = (pts.last.y - oy) / unit;
    geom[g + 15] = math.log((w + 1e-3) / (h + 1e-3)) / 4;
    prevEnd = pts.last.t.toDouble();
  }
  return StrokeFeatures(n, shape, geom);
}
