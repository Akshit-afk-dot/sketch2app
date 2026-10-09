/// Drawing surface. One pointer draws; two fingers pan and zoom; with "stylus only", fingers always
/// pan so a resting palm never leaves ink (tablets, classroom boards).
library;

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../ink/ink_model.dart';
import '../../recognize/elements.dart';
import 'sketch_controller.dart';

class SketchCanvas extends StatefulWidget {
  const SketchCanvas({
    super.key,
    required this.controller,
    this.showOverlay = false,
  });

  final SketchController controller;
  final bool showOverlay;

  @override
  State<SketchCanvas> createState() => _SketchCanvasState();
}

class _SketchCanvasState extends State<SketchCanvas> {
  final _pointers = <int, Offset>{};
  int? _drawingPointer;
  double? _pinchStartDistance;
  Offset? _lastFocal;
  bool _fitted = false;

  SketchController get c => widget.controller;

  bool _draws(PointerDownEvent e) => switch (e.kind) {
    PointerDeviceKind.stylus || PointerDeviceKind.invertedStylus => true,
    PointerDeviceKind.mouse => e.buttons == kPrimaryMouseButton,
    PointerDeviceKind.touch => !c.stylusOnly,
    _ => false,
  };

  InkTool _toolOf(PointerDeviceKind k) => switch (k) {
    PointerDeviceKind.stylus || PointerDeviceKind.invertedStylus => InkTool.pen,
    PointerDeviceKind.mouse => InkTool.mouse,
    _ => InkTool.touch,
  };

  void _down(PointerDownEvent e) {
    _pointers[e.pointer] = e.localPosition;
    final touches = _pointers.length;
    if (touches == 1 && _draws(e)) {
      _drawingPointer = e.pointer;
      c.beginStroke(e.localPosition, _toolOf(e.kind));
    } else if (touches >= 2) {
      if (_drawingPointer != null) c.cancelStroke();
      _drawingPointer = null;
      _startGesture();
    } else {
      _startGesture(); // a single non-drawing finger pans
    }
  }

  void _startGesture() {
    final pts = _pointers.values.toList();
    _lastFocal = pts.reduce((a, b) => a + b) / pts.length.toDouble();
    _pinchStartDistance = pts.length >= 2 ? (pts[0] - pts[1]).distance : null;
  }

  void _move(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.localPosition;
    if (e.pointer == _drawingPointer) {
      c.extendStroke(e.localPosition);
      return;
    }
    if (_drawingPointer != null) return;
    final pts = _pointers.values.toList();
    final focal = pts.reduce((a, b) => a + b) / pts.length.toDouble();
    if (_lastFocal != null) c.pan(focal - _lastFocal!);
    if (pts.length >= 2 &&
        _pinchStartDistance != null &&
        _pinchStartDistance! > 0) {
      final d = (pts[0] - pts[1]).distance;
      c.zoom(d / _pinchStartDistance!, focal);
      _pinchStartDistance = d;
    }
    _lastFocal = focal;
  }

  void _up(PointerEvent e) {
    _pointers.remove(e.pointer);
    if (e.pointer == _drawingPointer) {
      _drawingPointer = null;
      c.endStroke();
    }
    if (_pointers.isNotEmpty) _startGesture();
  }

  void _signal(PointerSignalEvent e) {
    if (e is PointerScrollEvent) {
      c.zoom(math.pow(0.999, e.scrollDelta.dy).toDouble(), e.localPosition);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!_fitted && constraints.biggest.isFinite) {
          _fitted = true;
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => c.fitTo(constraints.biggest),
          );
        }
        return Listener(
          onPointerDown: _down,
          onPointerMove: _move,
          onPointerUp: _up,
          onPointerCancel: _up,
          onPointerSignal: _signal,
          child: ClipRect(
            child: ListenableBuilder(
              listenable: c,
              builder: (context, _) => CustomPaint(
                size: Size.infinite,
                painter: _InkPainter(
                  c,
                  Theme.of(context).colorScheme,
                  showOverlay: widget.showOverlay,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _InkPainter extends CustomPainter {
  _InkPainter(this.c, this.scheme, {required this.showOverlay});

  final SketchController c;
  final ColorScheme scheme;
  final bool showOverlay;

  static const _typeColors = {
    ElementType.btn: Colors.indigo,
    ElementType.input: Colors.teal,
    ElementType.text: Colors.blueGrey,
    ElementType.heading: Colors.deepPurple,
    ElementType.img: Colors.orange,
    ElementType.card: Colors.brown,
    ElementType.appbar: Colors.red,
    ElementType.bottomnav: Colors.red,
  };

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = scheme.surfaceContainerLow,
    );
    canvas.save();
    canvas.translate(c.offset.dx, c.offset.dy);
    canvas.scale(c.scale);

    final label = TextPainter(textDirection: TextDirection.ltr);
    for (var i = 0; i < c.doc.frames.length; i++) {
      final b = c.doc.frames[i].box;
      final r = RRect.fromRectAndRadius(
        Rect.fromLTWH(b.x, b.y, b.w, b.h),
        const Radius.circular(24),
      );
      canvas.drawRRect(
        r.shift(const Offset(0, 3)),
        Paint()..color = Colors.black12,
      );
      canvas.drawRRect(r, Paint()..color = Colors.white);
      canvas.drawRRect(
        r,
        Paint()
          ..color = scheme.outlineVariant
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 / c.scale,
      );
      label
        ..text = TextSpan(
          text: 'Screen ${i + 1}',
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 14),
        )
        ..layout();
      label.paint(canvas, Offset(b.x + 4, b.y - 22));
    }

    final ink = Paint()
      ..color = const Color(0xFF1B1B1F)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (final s in c.doc.strokes) {
      canvas.drawPath(_path(s.points), ink);
    }
    final cur = c.currentStroke;
    if (cur != null) canvas.drawPath(_path(cur), ink);

    final overlay = c.overlay;
    if (showOverlay && overlay != null) _paintOverlay(canvas, overlay, label);
    canvas.restore();
  }

  void _paintOverlay(Canvas canvas, ElementList overlay, TextPainter label) {
    for (final e in overlay.elements) {
      final color = _typeColors[e.type] ?? Colors.green;
      final rect = Rect.fromLTWH(e.box.x, e.box.y, e.box.w, e.box.h).inflate(3);
      canvas.drawRect(
        rect,
        Paint()
          ..color = color.withValues(alpha: 0.8)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5 / c.scale,
      );
      label
        ..text = TextSpan(
          text: e.text == null ? e.type.json : '${e.type.json}: ${e.text}',
          style: TextStyle(
            color: color,
            fontSize: 11,
            backgroundColor: Colors.white70,
          ),
        )
        ..layout();
      label.paint(canvas, rect.topLeft - const Offset(0, 14));
    }
    final arrowPaint = Paint()
      ..color = Colors.pink
      ..strokeWidth = 3 / c.scale
      ..style = PaintingStyle.stroke;
    for (final a in overlay.arrows) {
      canvas.drawLine(
        Offset(a.tail.$1, a.tail.$2),
        Offset(a.head.$1, a.head.$2),
        arrowPaint,
      );
      canvas.drawCircle(Offset(a.head.$1, a.head.$2), 6 / c.scale, arrowPaint);
    }
  }

  Path _path(List<InkPoint> pts) {
    final p = Path()..moveTo(pts.first.x, pts.first.y);
    if (pts.length == 1) {
      p.lineTo(pts.first.x + 0.1, pts.first.y);
    }
    for (final q in pts.skip(1)) {
      p.lineTo(q.x, q.y);
    }
    return p;
  }

  @override
  bool shouldRepaint(covariant _InkPainter old) => true;
}
