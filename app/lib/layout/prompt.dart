/// Element list -> layout-LLM prompt text: an exact port of ml/s2a/layout/prompt.py.
///
/// Shared fixtures (spec/fixtures/prompt) check that the app sends the model exactly the text format it
/// was trained on.
library;

import 'dart:math' as math;

import '../ink/ink_model.dart';
import '../recognize/elements.dart';

const promptInstruction =
    'Convert these sketch elements to a Sketch2App UI spec v1 (canonical JSON only).';
const _maxText = 40;

/// Round half up for the non-negative-or-negative values we quantise (Python side uses floor(v + 0.5)).
int halfUp(double v) => (v + 0.5).floor();

List<InkFrame> readingOrderFrames(List<InkFrame> frames) {
  bool sameRow(InkFrame a, InkFrame b) =>
      (a.box.cy - b.box.cy).abs() < 0.5 * math.min(a.box.h, b.box.h);
  final sorted = [...frames]
    ..sort((a, b) {
      final c = a.box.y.compareTo(b.box.y);
      return c != 0 ? c : a.box.x.compareTo(b.box.x);
    });
  final rows = <List<InkFrame>>[];
  for (final f in sorted) {
    final row = rows.where((r) => sameRow(r.first, f)).firstOrNull;
    if (row != null) {
      row.add(f);
    } else {
      rows.add([f]);
    }
  }
  return [
    for (final r in rows) ...(r..sort((a, b) => a.box.x.compareTo(b.box.x))),
  ];
}

double _distToBox(Box b, double x, double y) {
  final dx = math.max(math.max(b.x - x, 0.0), x - b.right);
  final dy = math.max(math.max(b.y - y, 0.0), y - b.bottom);
  return math.sqrt(dx * dx + dy * dy);
}

bool _contains(Box b, double x, double y, [double pad = 0]) =>
    x >= b.x - pad &&
    x <= b.right + pad &&
    y >= b.y - pad &&
    y <= b.bottom + pad;

int _nearestFrame(List<InkFrame> frames, double x, double y) {
  var best = 0;
  for (var k = 1; k < frames.length; k++) {
    if (_distToBox(frames[k].box, x, y) < _distToBox(frames[best].box, x, y)) {
      best = k;
    }
  }
  return best;
}

int _frameOf(SketchElement e, List<InkFrame> frames) {
  for (var k = 0; k < frames.length; k++) {
    if (_contains(frames[k].box, e.box.cx, e.box.cy)) return k;
  }
  return _nearestFrame(frames, e.box.cx, e.box.cy);
}

String? cleanPromptText(String? t) {
  if (t == null) return null;
  final s = t
      .replaceAll('"', "'")
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .join(' ');
  final runes = s.runes.toList();
  final out = String.fromCharCodes(runes.take(_maxText));
  return out.isEmpty ? null : out;
}

String formatElements(ElementList el) {
  final frames = readingOrderFrames(el.frames);
  if (frames.isEmpty) return '';
  final perFrame = [for (final _ in frames) <SketchElement>[]];
  for (final e in el.elements) {
    perFrame[_frameOf(e, frames)].add(e);
  }
  final lines = <String>[];
  final number = <int, int>{};
  for (var k = 0; k < frames.length; k++) {
    final f = frames[k].box;
    lines.add('S${k + 1}');
    final els = perFrame[k]
      ..sort((a, b) {
        final y = halfUp(a.box.y).compareTo(halfUp(b.box.y));
        if (y != 0) return y;
        final x = halfUp(a.box.x).compareTo(halfUp(b.box.x));
        return x != 0 ? x : a.id.compareTo(b.id);
      });
    for (final e in els) {
      number[e.id] = number.length + 1;
      final q = [
        halfUp(100 * (e.box.x - f.x) / f.w),
        halfUp(100 * (e.box.y - f.y) / f.h),
        halfUp(100 * e.box.w / f.w),
        halfUp(100 * e.box.h / f.h),
      ];
      final text = cleanPromptText(e.text);
      lines.add(
        '${number[e.id]} ${e.type.json} ${q.join(',')}${text == null ? '' : ' "$text"'}',
      );
    }
  }
  final unit = frames.map((f) => f.box.w).reduce(math.min);
  for (final a in el.arrows) {
    final (tx, ty) = a.tail;
    SketchElement? src;
    final inside = el.elements
        .where((e) => _contains(e.box, tx, ty, 0.04 * unit))
        .toList();
    if (inside.isNotEmpty) {
      src = inside.reduce((p, q) => q.box.area < p.box.area ? q : p);
    } else {
      var best = 0.15 * unit;
      for (final e in el.elements) {
        final d = _distToBox(e.box, tx, ty);
        if (d < best) {
          best = d;
          src = e;
        }
      }
    }
    if (src == null) continue;
    final (hx, hy) = a.head;
    var dst = -1;
    for (var k = 0; k < frames.length; k++) {
      if (_contains(frames[k].box, hx, hy)) {
        dst = k;
        break;
      }
    }
    if (dst < 0) dst = _nearestFrame(frames, hx, hy);
    if (_frameOf(src, frames) != dst) {
      lines.add('L ${number[src.id]}>S${dst + 1}');
    }
  }
  return lines.join('\n');
}

String buildPrompt(ElementList el) =>
    '$promptInstruction\n${formatElements(el)}';
