/// Canvas state: the ink document, tools, undo/redo and the view transform.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../ink/ink_model.dart';
import '../../recognize/elements.dart';

enum DrawTool { pen, eraser }

/// Phone-like portrait frame; 360 logical px wide like a typical Android phone.
const Size frameSize = Size(360, 760);
const double frameGap = 120;

class _Snapshot {
  _Snapshot(InkDocument d) : strokes = [...d.strokes], frames = [...d.frames];
  final List<InkStroke> strokes;
  final List<InkFrame> frames;
}

class SketchController extends ChangeNotifier {
  SketchController() {
    addFrame(record: false);
  }

  InkDocument _doc = InkDocument();
  InkDocument get doc => _doc;

  DrawTool tool = DrawTool.pen;

  /// When true only a stylus draws and fingers pan/zoom (palm rejection on tablets and boards).
  bool stylusOnly = false;

  /// Debug overlay from the last conversion: recognized element boxes and arrows.
  ElementList? overlay;

  final _undo = <_Snapshot>[];
  final _redo = <_Snapshot>[];
  final _clock = Stopwatch()..start();
  List<InkPoint>? _current;
  InkTool _currentTool = InkTool.touch;
  bool _erasedThisGesture = false;

  /// View transform: screen = canvas * scale + offset.
  double scale = 1;
  Offset offset = Offset.zero;

  /// Bumped on every ink change so listeners (auto-convert) can tell ink edits from view changes.
  int revision = 0;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  List<InkPoint>? get currentStroke => _current;

  Offset toCanvas(Offset screen) => (screen - offset) / scale;

  void _record() {
    _undo.add(_Snapshot(_doc));
    if (_undo.length > 200) _undo.removeAt(0);
    _redo.clear();
  }

  void _changed() {
    revision++;
    overlay = null;
    notifyListeners();
  }

  void beginStroke(Offset screen, InkTool kind) {
    if (tool == DrawTool.eraser) {
      _erasedThisGesture = false;
      eraseAt(screen);
      return;
    }
    final p = toCanvas(screen);
    _currentTool = kind;
    _current = [InkPoint(p.dx, p.dy, _clock.elapsedMilliseconds)];
    notifyListeners();
  }

  void extendStroke(Offset screen) {
    if (tool == DrawTool.eraser) {
      eraseAt(screen);
      return;
    }
    final cur = _current;
    if (cur == null) return;
    final p = toCanvas(screen);
    final last = cur.last;
    // Drop sub-pixel moves: they add points without adding shape.
    if ((p.dx - last.x).abs() + (p.dy - last.y).abs() < 0.75 / scale) return;
    cur.add(InkPoint(p.dx, p.dy, _clock.elapsedMilliseconds));
    notifyListeners();
  }

  void endStroke() {
    final cur = _current;
    _current = null;
    if (cur == null || tool == DrawTool.eraser) return;
    _record();
    _doc.strokes.add(InkStroke(_doc.nextStrokeId, cur, tool: _currentTool));
    _changed();
  }

  /// A second finger landed mid-stroke: that stroke was the start of a pinch, not ink.
  void cancelStroke() {
    _current = null;
    notifyListeners();
  }

  void eraseAt(Offset screen) {
    final p = toCanvas(screen);
    final r = 14 / scale;
    final hit = _doc.strokes.where(
      (s) =>
          s.box.inflate(r).containsPoint(p.dx, p.dy) &&
          s.points.any((q) => (q.x - p.dx).abs() < r && (q.y - p.dy).abs() < r),
    );
    if (hit.isEmpty) return;
    if (!_erasedThisGesture) {
      _record();
      _erasedThisGesture = true;
    }
    final ids = hit.map((s) => s.id).toSet();
    _doc.strokes.removeWhere((s) => ids.contains(s.id));
    _changed();
  }

  void addFrame({bool record = true}) {
    if (record) _record();
    final x = _doc.frames.isEmpty
        ? 0.0
        : _doc.frames.map((f) => f.box.right).reduce(math.max) + frameGap;
    _doc.frames.add(
      InkFrame(_doc.nextFrameId, Box(x, 0, frameSize.width, frameSize.height)),
    );
    _changed();
  }

  void removeLastFrame() {
    if (_doc.frames.length <= 1) return;
    _record();
    _doc.frames.removeLast();
    _changed();
  }

  void clear() {
    _record();
    _doc = InkDocument(frames: [..._doc.frames]);
    _changed();
  }

  void load(InkDocument d) {
    _record();
    _doc = InkDocument(strokes: [...d.strokes], frames: [...d.frames]);
    _changed();
  }

  void undo() {
    if (_undo.isEmpty) return;
    _redo.add(_Snapshot(_doc));
    final s = _undo.removeLast();
    _doc = InkDocument(strokes: s.strokes, frames: s.frames);
    _changed();
  }

  void redo() {
    if (_redo.isEmpty) return;
    _undo.add(_Snapshot(_doc));
    final s = _redo.removeLast();
    _doc = InkDocument(strokes: s.strokes, frames: s.frames);
    _changed();
  }

  void setTool(DrawTool t) {
    tool = t;
    notifyListeners();
  }

  void setOverlay(ElementList? o) {
    overlay = o;
    notifyListeners();
  }

  /// Zoom around a focal point (screen coordinates), clamped to a usable range.
  void zoom(double factor, Offset focal) {
    final next = (scale * factor).clamp(0.2, 5.0);
    final canvasFocal = toCanvas(focal);
    scale = next;
    offset = focal - canvasFocal * scale;
    notifyListeners();
  }

  void pan(Offset delta) {
    offset += delta;
    notifyListeners();
  }

  /// Fit all frames into the viewport with a margin.
  void fitTo(Size viewport) {
    if (_doc.frames.isEmpty || viewport.isEmpty) return;
    final all = _doc.frames
        .map((f) => f.box)
        .reduce((a, b) => a.union(b))
        .inflate(40);
    scale = math
        .min(viewport.width / all.w, viewport.height / all.h)
        .clamp(0.2, 2.0);
    offset = Offset(
      (viewport.width - all.w * scale) / 2 - all.x * scale,
      (viewport.height - all.h * scale) / 2 - all.y * scale,
    );
    notifyListeners();
  }
}
