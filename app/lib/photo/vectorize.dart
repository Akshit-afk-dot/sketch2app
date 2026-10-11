/// Photo of a paper sketch -> strokes ("pseudo-ink") for the stroke recognizer.
///
/// Why vectorize instead of training a separate image detector: the rest of the system (recognizer,
/// handwriting, layout, editing on the canvas) works on strokes, so a photo turned into strokes reuses all
/// of it, and the user can fix stray strokes with the eraser before converting. The cost is that strokes
/// lose their real drawing order and timing; the photo recognizer is therefore trained on exactly these
/// pseudo-strokes (synthetic photos -> this code via `dart run tool/batch.dart vectorize`), never on pen ink.
///
/// Steps: paper detection on a coarse grid -> adaptive threshold (Bradley-Roth) -> majority smoothing and
/// speck/blob removal -> Zhang-Suen thinning -> skeleton graph -> spur pruning -> strokes joined straight
/// through junctions -> Ramer-Douglas-Peucker -> reading order with synthetic timing.
///
/// Pure Dart and deterministic: the app and the training-data tool must produce identical strokes.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../ink/ink_model.dart';

/// Photos are downscaled to this long side first: enough for ~3 px pen lines and handwriting ~15 px high
/// on a 3-screen page, and thinning stays well under a second on a phone.
const int photoLongSide = 1280;

/// 8-bit grayscale image, row-major.
class GrayImage {
  GrayImage(this.width, this.height, this.pixels)
    : assert(pixels.length == width * height);

  /// From RGBA bytes (Flutter's `ImageByteFormat.rawRgba`, or package:image), Rec. 601 luma.
  factory GrayImage.fromRgba(int width, int height, Uint8List rgba) {
    final out = Uint8List(width * height);
    for (var i = 0, j = 0; i < out.length; i++, j += 4) {
      out[i] = (299 * rgba[j] + 587 * rgba[j + 1] + 114 * rgba[j + 2]) ~/ 1000;
    }
    return GrayImage(width, height, out);
  }

  final int width;
  final int height;
  final Uint8List pixels;

  /// Area-average downscale so the long side is at most [longSide] (never upscales). Done here rather
  /// than by the platform decoder so the laptop tools and the device resize identically.
  GrayImage fitWithin(int longSide) {
    final scale = longSide / math.max(width, height);
    if (scale >= 1) return this;
    final w = math.max(1, (width * scale).round());
    final h = math.max(1, (height * scale).round());
    final out = Uint8List(w * h);
    for (var y = 0; y < h; y++) {
      final y0 = y * height ~/ h, y1 = math.max(y0 + 1, (y + 1) * height ~/ h);
      for (var x = 0; x < w; x++) {
        final x0 = x * width ~/ w, x1 = math.max(x0 + 1, (x + 1) * width ~/ w);
        var sum = 0;
        for (var yy = y0; yy < y1; yy++) {
          final row = yy * width;
          for (var xx = x0; xx < x1; xx++) {
            sum += pixels[row + xx];
          }
        }
        out[y * w + x] = sum ~/ ((y1 - y0) * (x1 - x0));
      }
    }
    return GrayImage(w, h, out);
  }
}

class VectorizeResult {
  const VectorizeResult({
    required this.ink,
    required this.page,
    required this.inkPixels,
    required this.strokeWidth,
    required this.micros,
  });

  /// Strokes in image pixel coordinates, reading order, synthetic timestamps; no template frames.
  final InkDocument ink;

  /// Detected paper area (the whole image when no background is visible).
  final Box page;
  final int inkPixels;

  /// Estimated pen width in pixels (ink area / skeleton length).
  final double strokeWidth;

  /// Per-step wall time in microseconds, for the debug overlay and the latency table.
  final Map<String, int> micros;
}

// Paper detection grid cell (px). Coarse on purpose: paper is a large bright region, ink barely moves a
// cell's mean, and 8x8 cells make flood fills cheap.
const _cell = 8;

// Bradley-Roth: ink if darker than the local mean by 15% and by at least 16 grey levels; the absolute
// floor stops paper grain and JPEG noise in flat areas from becoming specks.
const _threshold = 0.15;
const _minContrast = 16;

// Components smaller than this (px at 1280) are specks; an i-dot drawn with a 3 px pen is ~12-20 px.
const _minArea = 10;

// Strokes join straight through a junction when they deviate by less than 45 degrees.
final _joinCos = math.cos(math.pi / 4);

VectorizeResult vectorize(GrayImage image) {
  final sw = Stopwatch()..start();
  final micros = <String, int>{};
  void lap(String name) {
    micros[name] = sw.elapsedMicroseconds;
    sw.reset();
  }

  final w = image.width, h = image.height;
  final (mask, page) = _pageMask(image);
  lap('page');
  var ink = _binarize(image, mask);
  ink = _majority(ink, w, h);
  final inkPixels = _removeSpecksAndBlobs(ink, w, h, page);
  lap('threshold');
  final skel = _thin(ink, w, h);
  var skelPixels = 0;
  for (final v in skel) {
    skelPixels += v;
  }
  final strokeWidth = skelPixels == 0 ? 1.0 : inkPixels / skelPixels;
  lap('thin');
  final paths = _trace(skel, w, h, strokeWidth);
  lap('trace');
  final strokes = _order(paths, h);
  lap('order');
  return VectorizeResult(
    ink: InkDocument(strokes: strokes),
    page: page,
    inkPixels: inkPixels,
    strokeWidth: strokeWidth,
    micros: micros,
  );
}

/// Paper = the largest bright region on a coarse grid (Otsu on cell means), holes filled, shrunk by one
/// cell so the paper's own edge is never taken for a drawn line. When the bright and dark cells are not
/// clearly different the photo is all paper.
(Uint8List, Box) _pageMask(GrayImage img) {
  final w = img.width, h = img.height;
  final gw = (w + _cell - 1) ~/ _cell, gh = (h + _cell - 1) ~/ _cell;
  final means = Uint8List(gw * gh);
  for (var gy = 0; gy < gh; gy++) {
    for (var gx = 0; gx < gw; gx++) {
      var sum = 0, n = 0;
      for (var y = gy * _cell; y < math.min(h, gy * _cell + _cell); y++) {
        for (var x = gx * _cell; x < math.min(w, gx * _cell + _cell); x++) {
          sum += img.pixels[y * w + x];
          n++;
        }
      }
      means[gy * gw + gx] = sum ~/ n;
    }
  }
  final full = Uint8List(w * h)..fillRange(0, w * h, 1);
  final wholeImage = Box(0, 0, w.toDouble(), h.toDouble());
  final (thr, darkMean, brightMean) = _otsu(means);
  if (brightMean - darkMean < 60) return (full, wholeImage);

  final paper = Uint8List(gw * gh);
  for (var i = 0; i < paper.length; i++) {
    paper[i] = means[i] > thr ? 1 : 0;
  }
  // Largest 4-connected paper component.
  final label = Int32List(gw * gh)..fillRange(0, gw * gh, -1);
  var best = -1, bestSize = 0;
  final queue = <int>[];
  for (var s = 0; s < paper.length; s++) {
    if (paper[s] == 0 || label[s] >= 0) continue;
    var size = 0;
    queue
      ..clear()
      ..add(s);
    label[s] = s;
    while (queue.isNotEmpty) {
      final c = queue.removeLast();
      size++;
      final cx = c % gw, cy = c ~/ gw;
      for (final (dx, dy) in const [(1, 0), (-1, 0), (0, 1), (0, -1)]) {
        final nx = cx + dx, ny = cy + dy;
        if (nx < 0 || ny < 0 || nx >= gw || ny >= gh) continue;
        final n = ny * gw + nx;
        if (paper[n] == 1 && label[n] < 0) {
          label[n] = s;
          queue.add(n);
        }
      }
    }
    if (size > bestSize) {
      best = s;
      bestSize = size;
    }
  }
  if (bestSize < paper.length ~/ 4) return (full, wholeImage);

  // Fill holes: everything the border cannot reach without crossing the paper belongs to the paper.
  final outside = Uint8List(gw * gh);
  queue.clear();
  for (var i = 0; i < paper.length; i++) {
    final cx = i % gw, cy = i ~/ gw;
    final border = cx == 0 || cy == 0 || cx == gw - 1 || cy == gh - 1;
    if (border && label[i] != best) {
      outside[i] = 1;
      queue.add(i);
    }
  }
  while (queue.isNotEmpty) {
    final c = queue.removeLast();
    final cx = c % gw, cy = c ~/ gw;
    for (final (dx, dy) in const [(1, 0), (-1, 0), (0, 1), (0, -1)]) {
      final nx = cx + dx, ny = cy + dy;
      if (nx < 0 || ny < 0 || nx >= gw || ny >= gh) continue;
      final n = ny * gw + nx;
      if (outside[n] == 0 && label[n] != best) {
        outside[n] = 1;
        queue.add(n);
      }
    }
  }
  // Shrink by one cell (8-neighbourhood) away from the outside.
  final cells = Uint8List(gw * gh);
  var l = gw, t = gh, r = -1, b = -1;
  for (var cy = 0; cy < gh; cy++) {
    for (var cx = 0; cx < gw; cx++) {
      var keep = outside[cy * gw + cx] == 0;
      for (var dy = -1; keep && dy <= 1; dy++) {
        for (var dx = -1; keep && dx <= 1; dx++) {
          final nx = cx + dx, ny = cy + dy;
          if (nx < 0 || ny < 0 || nx >= gw || ny >= gh) continue;
          if (outside[ny * gw + nx] == 1) keep = false;
        }
      }
      if (!keep) continue;
      cells[cy * gw + cx] = 1;
      l = math.min(l, cx);
      t = math.min(t, cy);
      r = math.max(r, cx);
      b = math.max(b, cy);
    }
  }
  if (r < 0) return (full, wholeImage);
  final mask = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    final row = (y ~/ _cell) * gw;
    for (var x = 0; x < w; x++) {
      mask[y * w + x] = cells[row + x ~/ _cell];
    }
  }
  final box = Box.fromLTRB(
    (l * _cell).toDouble(),
    (t * _cell).toDouble(),
    math.min(w, (r + 1) * _cell).toDouble(),
    math.min(h, (b + 1) * _cell).toDouble(),
  );
  return (mask, box);
}

/// Otsu threshold of 8-bit values: (threshold, mean below, mean above).
(int, double, double) _otsu(Uint8List values) {
  final hist = List<int>.filled(256, 0);
  for (final v in values) {
    hist[v]++;
  }
  final total = values.length;
  var sumAll = 0.0;
  for (var i = 0; i < 256; i++) {
    sumAll += i * hist[i];
  }
  var wB = 0, sumB = 0.0, bestVar = -1.0, thr = 127;
  for (var t = 0; t < 256; t++) {
    wB += hist[t];
    if (wB == 0) continue;
    final wF = total - wB;
    if (wF == 0) break;
    sumB += t * hist[t];
    final mB = sumB / wB, mF = (sumAll - sumB) / wF;
    final v = wB * wF * (mB - mF) * (mB - mF);
    if (v > bestVar) {
      bestVar = v;
      thr = t;
    }
  }
  var nD = 0, sD = 0.0, nB = 0, sB = 0.0;
  for (var i = 0; i < 256; i++) {
    if (i <= thr) {
      nD += hist[i];
      sD += i * hist[i];
    } else {
      nB += hist[i];
      sB += i * hist[i];
    }
  }
  return (thr, nD == 0 ? 0.0 : sD / nD, nB == 0 ? 255.0 : sB / nB);
}

/// Bradley-Roth adaptive threshold over a window of ~1/24 of the long side, inside the paper mask.
Uint8List _binarize(GrayImage img, Uint8List mask) {
  final w = img.width, h = img.height;
  final integral = Int32List((w + 1) * (h + 1));
  for (var y = 0; y < h; y++) {
    var row = 0;
    for (var x = 0; x < w; x++) {
      row += img.pixels[y * w + x];
      integral[(y + 1) * (w + 1) + x + 1] = integral[y * (w + 1) + x + 1] + row;
    }
  }
  final half = math.max(7, math.max(w, h) ~/ 48);
  final out = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    final y0 = math.max(0, y - half), y1 = math.min(h, y + half + 1);
    for (var x = 0; x < w; x++) {
      final i = y * w + x;
      if (mask[i] == 0) continue;
      final x0 = math.max(0, x - half), x1 = math.min(w, x + half + 1);
      final sum =
          integral[y1 * (w + 1) + x1] -
          integral[y0 * (w + 1) + x1] -
          integral[y1 * (w + 1) + x0] +
          integral[y0 * (w + 1) + x0];
      final area = (x1 - x0) * (y1 - y0);
      final p = img.pixels[i];
      if (p * area < sum * (1 - _threshold) &&
          sum - p * area >= _minContrast * area) {
        out[i] = 1;
      }
    }
  }
  return out;
}

/// 3x3 majority vote: fills pinholes in pen lines and removes single-pixel noise, which would otherwise
/// become skeleton spurs and tiny loops.
Uint8List _majority(Uint8List ink, int w, int h) {
  final out = Uint8List(w * h);
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final i = y * w + x;
      final n =
          ink[i - w - 1] +
          ink[i - w] +
          ink[i - w + 1] +
          ink[i - 1] +
          ink[i] +
          ink[i + 1] +
          ink[i + w - 1] +
          ink[i + w] +
          ink[i + w + 1];
      out[i] = n >= 5 ? 1 : 0;
    }
  }
  return out;
}

/// Drops 8-connected components that are specks (tiny) or blobs (large and mostly filled: shadows,
/// stains, a hand at the edge). Returns the ink pixel count left.
int _removeSpecksAndBlobs(Uint8List ink, int w, int h, Box page) {
  final seen = Uint8List(w * h);
  final comp = <int>[];
  final stack = <int>[];
  var kept = 0;
  final blobArea = page.area * 0.02;
  for (var s = 0; s < ink.length; s++) {
    if (ink[s] == 0 || seen[s] == 1) continue;
    comp.clear();
    stack
      ..clear()
      ..add(s);
    seen[s] = 1;
    var l = w, t = h, r = 0, b = 0;
    while (stack.isNotEmpty) {
      final c = stack.removeLast();
      comp.add(c);
      final cx = c % w, cy = c ~/ w;
      l = math.min(l, cx);
      r = math.max(r, cx);
      t = math.min(t, cy);
      b = math.max(b, cy);
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          final nx = cx + dx, ny = cy + dy;
          if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
          final n = ny * w + nx;
          if (ink[n] == 1 && seen[n] == 0) {
            seen[n] = 1;
            stack.add(n);
          }
        }
      }
    }
    final boxArea = (r - l + 1) * (b - t + 1);
    final blob = boxArea > blobArea && comp.length > 0.4 * boxArea;
    if (comp.length < _minArea || blob) {
      for (final c in comp) {
        ink[c] = 0;
      }
    } else {
      kept += comp.length;
    }
  }
  return kept;
}

/// Zhang-Suen thinning to a one-pixel-wide skeleton (the image border is treated as background).
Uint8List _thin(Uint8List ink, int w, int h) {
  final img = Uint8List.fromList(ink);
  for (var x = 0; x < w; x++) {
    img[x] = 0;
    img[(h - 1) * w + x] = 0;
  }
  for (var y = 0; y < h; y++) {
    img[y * w] = 0;
    img[y * w + w - 1] = 0;
  }
  var candidates = <int>[
    for (var i = 0; i < img.length; i++)
      if (img[i] == 1) i,
  ];
  final remove = <int>[];
  var changed = true;
  while (changed) {
    changed = false;
    for (final pass in const [0, 1]) {
      remove.clear();
      for (final i in candidates) {
        if (img[i] == 0) continue;
        final p2 = img[i - w], p3 = img[i - w + 1], p4 = img[i + 1];
        final p5 = img[i + w + 1], p6 = img[i + w], p7 = img[i + w - 1];
        final p8 = img[i - 1], p9 = img[i - w - 1];
        final b = p2 + p3 + p4 + p5 + p6 + p7 + p8 + p9;
        if (b < 2 || b > 6) continue;
        final a =
            (p2 == 0 && p3 == 1 ? 1 : 0) +
            (p3 == 0 && p4 == 1 ? 1 : 0) +
            (p4 == 0 && p5 == 1 ? 1 : 0) +
            (p5 == 0 && p6 == 1 ? 1 : 0) +
            (p6 == 0 && p7 == 1 ? 1 : 0) +
            (p7 == 0 && p8 == 1 ? 1 : 0) +
            (p8 == 0 && p9 == 1 ? 1 : 0) +
            (p9 == 0 && p2 == 1 ? 1 : 0);
        if (a != 1) continue;
        if (pass == 0) {
          if (p2 * p4 * p6 != 0 || p4 * p6 * p8 != 0) continue;
        } else {
          if (p2 * p4 * p8 != 0 || p2 * p6 * p8 != 0) continue;
        }
        remove.add(i);
      }
      for (final i in remove) {
        img[i] = 0;
      }
      if (remove.isNotEmpty) changed = true;
    }
    candidates = [
      for (final i in candidates)
        if (img[i] == 1) i,
    ];
  }
  return img;
}

/// A traced skeleton edge between two nodes (or a closed loop when both are -1).
class _Edge {
  _Edge(this.a, this.b, this.pts);
  final int a;
  final int b;
  final List<(double, double)> pts;
  bool removed = false;

  double get length {
    var s = 0.0;
    for (var k = 1; k < pts.length; k++) {
      s += _dist(pts[k - 1], pts[k]);
    }
    return s;
  }
}

double _dist((double, double) p, (double, double) q) {
  final dx = p.$1 - q.$1, dy = p.$2 - q.$2;
  return math.sqrt(dx * dx + dy * dy);
}

/// Skeleton -> polylines. Pixel graph: 4-neighbours, plus diagonals only where no orthogonal pixel
/// already connects the pair (otherwise staircases look like junctions). Pixels of degree != 2 are nodes;
/// touching junction pixels merge into one node at their centroid.
List<List<(double, double)>> _trace(Uint8List sk, int w, int h, double width) {
  List<int> nbrs(int i) {
    final x = i % w, y = i ~/ w;
    final out = <int>[];
    for (final (dx, dy) in const [(1, 0), (-1, 0), (0, 1), (0, -1)]) {
      final nx = x + dx, ny = y + dy;
      if (nx >= 0 && ny >= 0 && nx < w && ny < h && sk[ny * w + nx] == 1) {
        out.add(ny * w + nx);
      }
    }
    for (final (dx, dy) in const [(1, 1), (1, -1), (-1, 1), (-1, -1)]) {
      final nx = x + dx, ny = y + dy;
      if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
      if (sk[ny * w + nx] == 1 && sk[y * w + nx] == 0 && sk[ny * w + x] == 0) {
        out.add(ny * w + nx);
      }
    }
    return out;
  }

  final pixels = <int>[
    for (var i = 0; i < sk.length; i++)
      if (sk[i] == 1) i,
  ];
  final degree = <int, int>{for (final i in pixels) i: nbrs(i).length};
  // Node ids: clusters of adjacent junction pixels; endpoints and isolated pixels are their own node.
  final node = <int, int>{};
  final centers = <(double, double)>[];
  for (final i in pixels) {
    if (degree[i] == 2 || node.containsKey(i)) continue;
    final id = centers.length;
    final members = <int>[i];
    node[i] = id;
    if (degree[i]! >= 3) {
      for (var k = 0; k < members.length; k++) {
        for (final n in nbrs(members[k])) {
          if (degree[n]! >= 3 && !node.containsKey(n)) {
            node[n] = id;
            members.add(n);
          }
        }
      }
    }
    var sx = 0.0, sy = 0.0;
    for (final m in members) {
      sx += m % w;
      sy += m ~/ w;
    }
    centers.add((sx / members.length, sy / members.length));
  }

  (double, double) pt(int i) => ((i % w).toDouble(), (i ~/ w).toDouble());
  final edges = <_Edge>[];
  final visited = <int>{};
  final usedStart = <(int, int)>{};
  for (final start in pixels) {
    final a = node[start];
    if (a == null) continue;
    for (final first in nbrs(start)) {
      if (node[first] == a || usedStart.contains((start, first))) continue;
      if (node[first] == null && visited.contains(first)) continue;
      usedStart.add((start, first));
      final pts = <(double, double)>[centers[a], pt(first)];
      var prev = start, cur = first;
      while (node[cur] == null) {
        visited.add(cur);
        final next = nbrs(cur).where((n) => n != prev).toList();
        if (next.isEmpty) break; // cannot happen for degree 2; defensive
        prev = cur;
        cur = next.first;
        pts.add(pt(cur));
      }
      final b = node[cur];
      if (b == null) continue;
      usedStart.add((cur, prev));
      pts[pts.length - 1] = centers[b];
      edges.add(_Edge(a, b, pts));
    }
    if (degree[start] == 0) edges.add(_Edge(a, a, [centers[a]]));
  }
  // Closed loops have no node at all.
  for (final start in pixels) {
    if (node.containsKey(start) || visited.contains(start)) continue;
    final pts = <(double, double)>[pt(start)];
    visited.add(start);
    var prev = -1, cur = start;
    while (true) {
      final next = nbrs(cur).where((n) => n != prev).toList();
      final nxt = next.firstWhere(
        (n) => !visited.contains(n),
        orElse: () => -1,
      );
      if (nxt < 0) break;
      visited.add(nxt);
      pts.add(pt(nxt));
      prev = cur;
      cur = nxt;
    }
    pts.add(pt(start));
    edges.add(_Edge(-1, -1, pts));
  }

  // Spurs: short branches from a junction to a free end are thinning artefacts of a thick pen.
  final spur = math.max(3.0, 2 * width);
  final incident = <int, List<_Edge>>{};
  for (final e in edges) {
    if (e.a >= 0) incident.putIfAbsent(e.a, () => []).add(e);
    if (e.b >= 0 && e.b != e.a) incident.putIfAbsent(e.b, () => []).add(e);
  }
  int liveDegree(int n) => incident[n]!.where((e) => !e.removed).length;
  for (final e in edges) {
    if (e.a < 0 || e.a == e.b || e.length >= spur) continue;
    final da = liveDegree(e.a), db = liveDegree(e.b);
    if ((da == 1 && db >= 3) || (db == 1 && da >= 3)) e.removed = true;
  }

  // Join edge ends straight through each node; a node left with exactly two edges always joins.
  final partner = <(_Edge, int), (_Edge, int)>{};
  (double, double) dirAt(_Edge e, int end) {
    final pts = end == 0 ? e.pts : e.pts.reversed.toList();
    final o = pts.first;
    final reach = math.max(3.0, 3 * width);
    var p = pts.last;
    var s = 0.0;
    for (var k = 1; k < pts.length; k++) {
      s += _dist(pts[k - 1], pts[k]);
      if (s >= reach) {
        p = pts[k];
        break;
      }
    }
    final d = _dist(o, p);
    return d < 1e-9 ? (0, 0) : ((p.$1 - o.$1) / d, (p.$2 - o.$2) / d);
  }

  for (final entry in incident.entries) {
    final ends = <(_Edge, int)>[
      for (final e in entry.value)
        if (!e.removed) ...[
          if (e.a == entry.key) (e, 0),
          if (e.b == entry.key) (e, 1),
        ],
    ];
    if (ends.length == 2 && ends[0].$1 != ends[1].$1) {
      partner[ends[0]] = ends[1];
      partner[ends[1]] = ends[0];
      continue;
    }
    final pairs = <(double, int, int)>[];
    for (var i = 0; i < ends.length; i++) {
      for (var j = i + 1; j < ends.length; j++) {
        if (ends[i].$1 == ends[j].$1) continue;
        final di = dirAt(ends[i].$1, ends[i].$2);
        final dj = dirAt(ends[j].$1, ends[j].$2);
        final straight = -(di.$1 * dj.$1 + di.$2 * dj.$2);
        if (straight > _joinCos) pairs.add((straight, i, j));
      }
    }
    pairs.sort((p, q) => q.$1.compareTo(p.$1));
    final taken = <int>{};
    for (final (_, i, j) in pairs) {
      if (taken.contains(i) || taken.contains(j)) continue;
      taken.addAll([i, j]);
      partner[ends[i]] = ends[j];
      partner[ends[j]] = ends[i];
    }
  }

  // Walk chains of joined edges into strokes; leftover all-joined chains are closed loops.
  final done = <_Edge>{};
  final strokes = <List<(double, double)>>[];
  void walk(_Edge e0, int entry) {
    final out = <(double, double)>[];
    var e = e0, from = entry;
    while (!done.contains(e)) {
      done.add(e);
      final pts = from == 0 ? e.pts : e.pts.reversed.toList();
      out.addAll(out.isEmpty ? pts : pts.skip(1));
      final next = partner[(e, 1 - from)];
      if (next == null) break;
      e = next.$1;
      from = next.$2;
    }
    strokes.add(out);
  }

  for (final e in edges) {
    if (e.removed || done.contains(e)) continue;
    if (!partner.containsKey((e, 0))) {
      walk(e, 0);
    } else if (!partner.containsKey((e, 1))) {
      walk(e, 1);
    }
  }
  for (final e in edges) {
    if (!e.removed && !done.contains(e)) walk(e, 0);
  }
  return [for (final s in strokes) _rdp(s, 0.75)];
}

/// Ramer-Douglas-Peucker simplification (iterative, keeps both ends).
List<(double, double)> _rdp(List<(double, double)> pts, double eps) {
  if (pts.length < 3) return pts;
  final keep = List<bool>.filled(pts.length, false);
  keep[0] = keep[pts.length - 1] = true;
  final stack = <(int, int)>[(0, pts.length - 1)];
  while (stack.isNotEmpty) {
    final (s, e) = stack.removeLast();
    var best = -1.0, at = -1;
    final (ax, ay) = pts[s];
    final (bx, by) = pts[e];
    final dx = bx - ax, dy = by - ay;
    final len = math.sqrt(dx * dx + dy * dy);
    for (var k = s + 1; k < e; k++) {
      final (px, py) = pts[k];
      final d = len < 1e-9
          ? _dist(pts[k], pts[s])
          : ((px - ax) * dy - (py - ay) * dx).abs() / len;
      if (d > best) {
        best = d;
        at = k;
      }
    }
    if (best > eps) {
      keep[at] = true;
      stack
        ..add((s, at))
        ..add((at, e));
    }
  }
  return [
    for (var k = 0; k < pts.length; k++)
      if (keep[k]) pts[k],
  ];
}

/// Reading order (bands of 3% of the image height, then left to right) with timestamps as if drawn at a
/// steady speed: time inside a stroke follows arc length and the pause before a stroke grows with the
/// pen's travel from the previous one, so nearby strokes (letters of a word) stay close in time.
List<InkStroke> _order(List<List<(double, double)>> paths, int imageHeight) {
  final band = math.max(1.0, imageHeight * 0.03);
  final keyed = [
    for (final p in paths)
      (
        (p.map((q) => q.$2).reduce(math.min) / band).floor(),
        p.map((q) => q.$1).reduce(math.min),
        p,
      ),
  ]..sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
  final pxPerMs = imageHeight / 1500; // crossing the page takes ~1.5 s
  const strokeGapMs = 120.0;
  final strokes = <InkStroke>[];
  var t = 0.0;
  (double, double)? last;
  for (final (_, _, p) in keyed) {
    if (last != null) t += strokeGapMs + _dist(last, p.first) / pxPerMs;
    final pts = <InkPoint>[];
    for (var k = 0; k < p.length; k++) {
      if (k > 0) t += _dist(p[k - 1], p[k]) / pxPerMs;
      pts.add(InkPoint(p[k].$1, p[k].$2, t.round()));
    }
    strokes.add(InkStroke(strokes.length, pts));
    last = p.last;
  }
  return strokes;
}
