/// Rule-based stroke recognizer: ink -> element list, following the sketch legend literally.
///
/// Two jobs: the demo never dead-ends (it needs no model file), and it is the baseline the learned
/// recognizer must beat. All distances are relative to the screen frame width `u` so the rules do not
/// depend on canvas zoom. Each rule cites the legend line it implements.
library;

import 'dart:math' as math;

import '../ink/ink_model.dart';
import 'elements.dart';
import 'geometry.dart';

class _Text {
  _Text(this.strokes, this.box);
  final List<int> strokes;
  Box box;
  bool used = false;
}

class HeuristicRecognizer {
  const HeuristicRecognizer();

  ElementList recognize(InkDocument doc) {
    final strokes = {for (final s in doc.strokes) s.id: s};
    final feats = {for (final s in doc.strokes) s.id: StrokeFeatures.of(s)};
    final prims = {for (final e in feats.entries) e.key: e.value.classify()};

    final frames = <InkFrame>[...doc.frames];
    final frameStrokes = <int, List<int>>{};
    _findDrawnFrames(doc, feats, prims, frames, frameStrokes);
    if (frames.isEmpty && doc.strokes.isNotEmpty) {
      frames.add(
        InkFrame(
          0,
          doc.strokes.map((s) => s.box).reduce((a, b) => a.union(b)).inflate(4),
        ),
      );
    }

    final consumed = <int>{for (final ids in frameStrokes.values) ...ids};
    final arrows = _findArrows(doc, feats, frames, consumed);

    final elements = <SketchElement>[];
    for (final frame in frames) {
      final ids = [
        for (final s in doc.strokes)
          if (!consumed.contains(s.id) &&
              frame.box.containsPoint(s.box.cx, s.box.cy))
            s.id,
      ];
      consumed.addAll(ids);
      _FrameRecognizer(frame, ids, strokes, feats, prims, elements).run();
    }
    return ElementList(
      frames: [for (final f in frames) InkFrame(f.id, f.box)],
      elements: elements,
      arrows: arrows,
    );
  }

  /// Legend: "screen = large rectangle (phone frame)". A portrait rectangle that encloses at least
  /// three other strokes and is not itself inside another frame.
  void _findDrawnFrames(
    InkDocument doc,
    Map<int, StrokeFeatures> feats,
    Map<int, Primitive> prims,
    List<InkFrame> frames,
    Map<int, List<int>> frameStrokes,
  ) {
    final candidates = <int>[];
    for (final s in doc.strokes) {
      if (prims[s.id] != Primitive.rect) continue;
      final b = feats[s.id]!.box;
      final aspect = b.h / math.max(b.w, 1e-6);
      if (aspect < 1.2 || aspect > 3.0) continue;
      final inside = doc.strokes
          .where((o) => o.id != s.id && b.containsPoint(o.box.cx, o.box.cy))
          .length;
      final insideTemplate = doc.frames.any((f) => b.coveredBy(f.box) > 0.8);
      if (inside >= 3 && !insideTemplate) candidates.add(s.id);
    }
    for (final id in candidates) {
      final b = feats[id]!.box;
      final nested = candidates.any(
        (o) =>
            o != id &&
            feats[o]!.box.area > b.area &&
            b.coveredBy(feats[o]!.box) > 0.8,
      );
      if (nested) continue;
      final frameId = frames.isEmpty
          ? 0
          : frames.map((f) => f.id).reduce(math.max) + 1;
      frames.add(InkFrame(frameId, b));
      frameStrokes[frameId] = [id];
    }
    frames.sort((a, b) => a.box.x.compareTo(b.box.x));
  }

  /// Legend: "navigation = arrow from an element to another screen frame". Any long stroke whose ends
  /// are in different frames (or one end outside all frames), plus small head strokes near its end.
  List<SketchArrow> _findArrows(
    InkDocument doc,
    Map<int, StrokeFeatures> feats,
    List<InkFrame> frames,
    Set<int> consumed,
  ) {
    if (frames.length < 2) return [];
    final u =
        frames.map((f) => f.box.w).reduce((a, b) => a + b) / frames.length;
    int? frameAt(double x, double y) {
      for (final f in frames) {
        if (f.box.containsPoint(x, y)) return f.id;
      }
      return null;
    }

    final arrows = <SketchArrow>[];
    for (final s in doc.strokes) {
      if (consumed.contains(s.id) || feats[s.id]!.length < 0.2 * u) continue;
      // Only the shaft's neighbours in drawing order can be its head (ids follow drawing order).
      final a = s.points.first, b = s.points.last;
      final fa = frameAt(a.x, a.y), fb = frameAt(b.x, b.y);
      if (fa == fb && fa != null) continue;
      if (fa == null && fb == null) continue;
      final ids = [s.id];
      consumed.add(s.id);
      // Head strokes: short strokes drawn right after the shaft, near its end.
      for (final o in doc.strokes) {
        if (consumed.contains(o.id) ||
            (o.id - s.id).abs() > 3 ||
            feats[o.id]!.box.diagonal > 0.12 * u) {
          continue;
        }
        final near = feats[o.id]!.box.inflate(0.04 * u).containsPoint(b.x, b.y);
        if (near) {
          ids.add(o.id);
          consumed.add(o.id);
        }
      }
      arrows.add(
        SketchArrow(
          id: arrows.length,
          tail: (a.x, a.y),
          head: (b.x, b.y),
          strokes: ids,
        ),
      );
    }
    return arrows;
  }
}

class _FrameRecognizer {
  _FrameRecognizer(
    this.frame,
    this.ids,
    this.strokes,
    this.feats,
    this.prims,
    this.out,
  ) : u = frame.box.w,
      h = frame.box.h;

  final InkFrame frame;
  final List<int> ids;
  final Map<int, InkStroke> strokes;
  final Map<int, StrokeFeatures> feats;
  final Map<int, Primitive> prims;
  final List<SketchElement> out;
  final double u;
  final double h;
  final used = <int>{};
  late final List<_Text> texts;

  Box box(int id) => feats[id]!.box;
  Primitive prim(int id) => prims[id]!;
  Iterable<int> free() => ids.where((i) => !used.contains(i));

  void emit(
    ElementType type,
    List<int> owned, {
    List<int> textStrokes = const [],
  }) {
    final all = {...owned, ...textStrokes}.toList()..sort();
    used.addAll(all);
    out.add(
      SketchElement(
        id: out.length,
        type: type,
        box: all.map(box).reduce((a, b) => a.union(b)),
        frame: frame.id,
        strokes: all,
        textStrokes: [...textStrokes]..sort(),
      ),
    );
  }

  bool isLong(int id) => box(id).w >= 0.15 * u;
  bool isShapeStroke(int id) => switch (prim(id)) {
    Primitive.rect ||
    Primitive.ellipse ||
    Primitive.wavy => box(id).diagonal > 0.04 * u,
    Primitive.hline => isLong(id),
    _ => false,
  };

  void run() {
    _menus();
    texts = _groupText();
    _bands();
    _ellipses();
    _lines(); // before rects, so an input box below a heading cannot take the heading's words
    _rects();
    _wavy();
    _leftoverText();
  }

  /// Legend: "menu = three short lines". Three short horizontal strokes stacked closely.
  void _menus() {
    final short =
        free()
            .where(
              (i) =>
                  prim(i) == Primitive.hline &&
                  box(i).w < 0.15 * u &&
                  box(i).w > 0.03 * u,
            )
            .toList()
          ..sort((a, b) => box(a).y.compareTo(box(b).y));
    for (var i = 0; i + 2 < short.length; i++) {
      final trio = short.sublist(i, i + 3);
      if (trio.any(used.contains)) continue;
      final b = trio.map(box).reduce((x, y) => x.union(y));
      final aligned = trio.every((t) => (box(t).cx - b.cx).abs() < 0.05 * u);
      if (aligned && b.h < 0.12 * u) emit(ElementType.menu, trio);
    }
  }

  /// Handwriting candidates: small strokes that are not clear shapes, clustered into words/lines.
  List<_Text> _groupText() {
    // Long diagonals are the X of an image, never letters.
    final cand = free()
        .where(
          (i) =>
              !isShapeStroke(i) &&
              box(i).h < 0.15 * u &&
              !(prim(i) == Primitive.diag && box(i).diagonal > 0.1 * u),
        )
        .toList();
    final parent = {for (final i in cand) i: i};
    int find(int x) => parent[x] == x ? x : parent[x] = find(parent[x]!);
    for (var a = 0; a < cand.length; a++) {
      for (var b = a + 1; b < cand.length; b++) {
        final x = box(cand[a]), y = box(cand[b]);
        final vOverlap = math.min(x.bottom, y.bottom) - math.max(x.y, y.y);
        final sameLine =
            vOverlap > 0.3 * math.min(x.h, y.h) ||
            (x.cy - y.cy).abs() < 0.5 * math.max(x.h, y.h);
        final gap = math.max(x.x, y.x) - math.min(x.right, y.right);
        if (sameLine && gap < 0.06 * u) parent[find(cand[a])] = find(cand[b]);
      }
    }
    final groups = <int, List<int>>{};
    for (final i in cand) {
      groups.putIfAbsent(find(i), () => []).add(i);
    }
    return [
      for (final g in groups.values)
        _Text(g, g.map(box).reduce((a, b) => a.union(b))),
    ];
  }

  Iterable<_Text> textsInside(Box b) =>
      texts.where((t) => !t.used && t.box.coveredBy(b.inflate(0.01 * u)) > 0.8);

  _Text? textAbove(Box b) {
    _Text? best;
    for (final t in texts.where((t) => !t.used)) {
      final gap = b.y - t.box.bottom;
      final xOverlap = math.min(b.right, t.box.right) - math.max(b.x, t.box.x);
      if (gap >= -0.01 * u &&
          gap < 0.08 * u &&
          xOverlap > 0.3 * t.box.w &&
          (best == null || t.box.bottom > best.box.bottom)) {
        best = t;
      }
    }
    return best;
  }

  _Text? textRightOf(Box b) {
    _Text? best;
    for (final t in texts.where((t) => !t.used)) {
      final gap = t.box.x - b.right;
      final sameLine = (t.box.cy - b.cy).abs() < math.max(b.h, t.box.h) * 0.7;
      if (sameLine &&
          gap > -0.01 * u &&
          gap < 0.08 * u &&
          (best == null || t.box.x < best.box.x)) {
        best = t;
      }
    }
    return best;
  }

  /// Settings-style rows put the label far left of the control, so callers can widen [maxGap].
  _Text? textLeftOf(Box b, {double maxGap = 0.1}) {
    _Text? best;
    for (final t in texts.where((t) => !t.used)) {
      final gap = b.x - t.box.right;
      final sameLine = (t.box.cy - b.cy).abs() < math.max(b.h, t.box.h) * 0.7;
      if (sameLine &&
          gap > -0.01 * u &&
          gap < maxGap * u &&
          (best == null || t.box.right > best.box.right)) {
        best = t;
      }
    }
    return best;
  }

  List<int> take(Iterable<_Text> ts) => [
    for (final t in ts) ...(t..used = true).strokes,
  ];

  /// Legend: "appbar = band across the top with a title"; "bottomnav = band across the bottom with
  /// 3-5 icons". A full-width rectangle, or a full-width line, near the frame's top/bottom edge.
  void _bands() {
    final fb = frame.box;
    for (final i in free().toList()) {
      final b = box(i);
      if (b.w < 0.8 * u) continue;
      final p = prim(i);
      // A band hugs the frame edge and holds only a title/icons; a box with other boxes in it is a card.
      final holdsBoxes = free().any(
        (j) => j != i && prim(j) == Primitive.rect && box(j).coveredBy(b) > 0.8,
      );
      if (p == Primitive.rect && holdsBoxes) continue;
      if (p == Primitive.rect && b.h < 0.15 * h && b.y - fb.y < 0.05 * h) {
        emit(ElementType.appbar, [i], textStrokes: take(textsInside(b)));
      } else if (p == Primitive.hline &&
          b.y - fb.y < 0.15 * h &&
          b.y - fb.y > 0.02 * h) {
        final band = Box.fromLTRB(fb.x, fb.y, fb.right, b.bottom);
        emit(ElementType.appbar, [i], textStrokes: take(textsInside(band)));
      } else if (p == Primitive.rect &&
          b.h < 0.15 * h &&
          fb.bottom - b.bottom < 0.05 * h) {
        emit(ElementType.bottomnav, [i]);
      } else if (p == Primitive.hline &&
          fb.bottom - b.y < 0.15 * h &&
          fb.bottom - b.y > 0.02 * h) {
        emit(ElementType.bottomnav, [i]);
      }
    }
  }

  void _ellipses() {
    final ell = free().where((i) => prim(i) == Primitive.ellipse).toList()
      ..sort((a, b) => box(b).area.compareTo(box(a).area));
    bool insidePill(Box b) => free().any((r) {
      final rb = box(r);
      return prim(r) == Primitive.rect &&
          rb.w > 1.7 * rb.h &&
          rb.w < 0.3 * u &&
          b.coveredBy(rb) > 0.9;
    });
    for (final i in ell) {
      if (used.contains(i)) continue;
      final b = box(i);
      if (insidePill(b)) {
        continue; // the switch knob; handled with its pill in _rects
      }
      final inner = free()
          .where((j) => j != i && box(j).coveredBy(b) > 0.9)
          .toList();
      final innerEllipse = inner
          .where((j) => prim(j) == Primitive.ellipse)
          .toList();
      // Legend: "switch = pill with a circle inside" (pill drawn as an elongated ellipse).
      if (b.w > 1.7 * b.h && innerEllipse.isNotEmpty) {
        final label = textLeftOf(b, maxGap: 0.7) ?? textRightOf(b);
        emit(ElementType.toggle, [
          i,
          ...innerEllipse,
        ], textStrokes: label == null ? const [] : take([label]));
      } else if (innerEllipse.isNotEmpty && b.w > 0.08 * u) {
        // Legend: "avatar = circle containing a smaller circle".
        emit(ElementType.avatar, [i, ...inner]);
      } else if (b.cx > frame.box.x + 0.6 * u &&
          b.cy > frame.box.y + 0.7 * h &&
          inner.isNotEmpty) {
        // Legend: "fab = circle with '+' near the bottom-right".
        for (final t in textsInside(b)) {
          t.used = true;
        }
        emit(ElementType.fab, [i, ...inner]);
      } else if (b.diagonal < 0.1 * u && textRightOf(b) != null) {
        // Legend: "radio = small circle + text".
        emit(ElementType.radio, [i], textStrokes: take([textRightOf(b)!]));
      } else {
        // Legend: "icon = small doodle or circle".
        for (final t in textsInside(b)) {
          t.used = true;
        }
        emit(ElementType.icon, [i, ...inner]);
      }
    }
  }

  void _rects() {
    final rects = free().where((i) => prim(i) == Primitive.rect).toList()
      ..sort(
        (a, b) => box(a).area.compareTo(box(b).area),
      ); // inner first, so cards see finished children
    for (final i in rects) {
      if (used.contains(i)) continue;
      final b = box(i);
      final inner = free()
          .where((j) => j != i && box(j).coveredBy(b.inflate(0.01 * u)) > 0.85)
          .toList();
      final innerEllipse = inner
          .where((j) => prim(j) == Primitive.ellipse && box(j).h < 1.1 * b.h)
          .toList();
      final diagonals = inner
          .where(
            (j) => prim(j) == Primitive.diag || prim(j) == Primitive.scribble,
          )
          .toList();
      final childElements = out
          .where((e) => e.frame == frame.id && e.box.coveredBy(b) > 0.85)
          .length;
      final textHere = textsInside(b).toList();
      if (b.w > 1.7 * b.h && b.w < 0.3 * u && innerEllipse.isNotEmpty) {
        // Legend: "switch = pill with a circle inside".
        final label = textLeftOf(b, maxGap: 0.7) ?? textRightOf(b);
        emit(ElementType.toggle, [
          i,
          ...innerEllipse,
        ], textStrokes: label == null ? const [] : take([label]));
      } else if (_isCross(b, diagonals)) {
        // Legend: "image = rectangle with an X".
        for (final t in textHere) {
          t.used = true;
        }
        emit(ElementType.img, [i, ...diagonals]);
      } else if (b.w < 0.09 * u && b.h < 0.09 * u && textRightOf(b) != null) {
        // Legend: "checkbox = small square + text".
        emit(ElementType.check, [i], textStrokes: take([textRightOf(b)!]));
      } else if (childElements > 0 ||
          inner.any(isShapeStroke) ||
          _textLineCount(textHere) > 1) {
        // Legend: "card = rectangle containing other elements".
        emit(ElementType.card, [i]);
      } else if (textHere.isNotEmpty) {
        // Legend: "button = rectangle containing text".
        emit(ElementType.btn, [i], textStrokes: take(textHere));
      } else {
        // Legend: "input = rectangle with label above". An empty tall box is more likely an image.
        final label = textAbove(b);
        if (label != null || b.h < 0.12 * u) {
          emit(ElementType.input, [
            i,
          ], textStrokes: label == null ? const [] : take([label]));
        } else {
          emit(ElementType.img, [i]);
        }
      }
    }
  }

  int _textLineCount(List<_Text> ts) {
    final ys = ts.map((t) => t.box.cy).toList()..sort();
    var lines = ys.isEmpty ? 0 : 1;
    for (var k = 1; k < ys.length; k++) {
      if (ys[k] - ys[k - 1] > 0.05 * u) lines++;
    }
    return lines;
  }

  /// An X: two diagonal strokes that each span most of the box, or one corner-to-corner stroke with few
  /// corners. Handwritten letters are small or wiggly, so button labels do not qualify.
  bool _isCross(Box b, List<int> inner) {
    bool spans(int j, double f) => box(j).w > f * b.w && box(j).h > f * b.h;
    final diagonals = inner
        .where((j) => prim(j) == Primitive.diag && spans(j, 0.5))
        .length;
    final oneStroke = inner.any(
      (j) => spans(j, 0.75) && feats[j]!.corners <= 4,
    );
    return diagonals >= 2 || oneStroke;
  }

  void _lines() {
    for (final i
        in free()
            .where((i) => prim(i) == Primitive.hline && isLong(i))
            .toList()) {
      final b = box(i);
      final above = textAbove(b);
      if (above != null && b.y - above.box.bottom < 0.05 * u) {
        // Legend: "heading = underlined words"; "input = underline with label" (line much wider than text).
        final type = b.w > 1.6 * above.box.w
            ? ElementType.input
            : ElementType.heading;
        emit(type, [i], textStrokes: take([above]));
      } else if (b.w > 0.4 * u) {
        // Legend: "divider = long horizontal line".
        emit(ElementType.divider, [i]);
      }
    }
  }

  /// Legend: "paragraph = 2+ wavy lines". Stacked wavy strokes form one paragraph.
  void _wavy() {
    final wavy = free().where((i) => prim(i) == Primitive.wavy).toList()
      ..sort((a, b) => box(a).y.compareTo(box(b).y));
    var group = <int>[];
    void flush() {
      if (group.isNotEmpty) emit(ElementType.para, group);
      group = [];
    }

    for (final i in wavy) {
      if (group.isNotEmpty && box(i).y - box(group.last).bottom > 0.08 * u) {
        flush();
      }
      group.add(i);
    }
    flush();
  }

  void _leftoverText() {
    for (final t in texts.where((t) => !t.used)) {
      // Never hand out a stroke twice: a group may share strokes with an element emitted earlier.
      t.strokes.removeWhere(used.contains);
      if (t.strokes.isEmpty) continue;
      t.box = t.strokes.map(box).reduce((a, b) => a.union(b));
      final aspect = t.box.w / math.max(t.box.h, 1e-6);
      // Legend: "icon = small doodle". Compact one- or two-stroke shapes are doodles, not words.
      final isDoodle =
          t.strokes.length <= 2 &&
          aspect > 0.6 &&
          aspect < 1.6 &&
          t.box.h > 0.04 * u;
      t.used = true;
      if (isDoodle) {
        // Also read as text: a short "x5" list mark looks like a doodle until handwriting reads it.
        emit(ElementType.icon, t.strokes, textStrokes: t.strokes);
      } else {
        emit(ElementType.text, const [], textStrokes: t.strokes);
      }
    }
    // Leftover medium lines are dividers; specks (dots, slips) are ignored rather than becoming text.
    for (final i in free().toList()) {
      if (prim(i) == Primitive.hline && box(i).w > 0.25 * u) {
        emit(ElementType.divider, [i]);
      } else if (box(i).diagonal > 0.03 * u) {
        emit(ElementType.text, const [], textStrokes: [i]);
      }
    }
  }
}
