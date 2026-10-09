/// The sketch legend, drawn with the same programmatic ink the samples use. Shown in-app so users
/// draw what the recognizer expects (and the synthetic data follows exactly these conventions).
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ink/ink_model.dart';
import '../ink/sketch_builder.dart';

class _Entry {
  const _Entry(this.name, this.how, this.draw);
  final String name;
  final String how;
  final void Function(SketchBuilder b) draw;
}

final _entries = <_Entry>[
  _Entry(
    'Screen',
    'Large rectangle, or tap "New screen"',
    (b) => b.rect(60, 0, 50, 100),
  ),
  _Entry(
    'Button',
    'Rectangle containing text',
    (b) => b.button(0, 0, 150, 44, 5),
  ),
  _Entry(
    'Input',
    'Rectangle with a label above (or underline with label)',
    (b) => b.input(0, 30, 160, 36, 5),
  ),
  _Entry('Text / heading', 'Handwritten words; underline them for a heading', (
    b,
  ) {
    b.word(0, 0, 6);
    b.line(0, 24, 90, 24);
  }),
  _Entry('Paragraph', '2+ wavy lines', (b) {
    b.wavy(0, 0, 160);
    b.wavy(0, 22, 130);
  }),
  _Entry('Image', 'Rectangle with an X', (b) => b.imageBox(0, 0, 140, 80)),
  _Entry('Icon / menu', 'Small doodle or circle; menu = three short lines', (
    b,
  ) {
    b.ellipse(15, 15, 12, 12);
    for (final y in [6.0, 14.0, 22.0]) {
      b.line(60, y, 84, y);
    }
  }),
  _Entry('Avatar', 'Circle containing a smaller circle', (b) {
    b.ellipse(40, 40, 36, 36);
    b.ellipse(40, 32, 12, 12);
  }),
  _Entry('Checkbox / radio', 'Small square or circle + text', (b) {
    b.rect(0, 0, 18, 18);
    b.word(26, 1, 4);
    b.ellipse(9, 45, 9, 9);
    b.word(26, 37, 4);
  }),
  _Entry('Switch', 'Pill with a circle inside', (b) {
    b.rect(0, 0, 64, 28);
    b.ellipse(15, 14, 9, 9);
  }),
  _Entry('Divider', 'Long horizontal line', (b) => b.line(0, 10, 180, 11)),
  _Entry('Card', 'Rectangle containing other elements', (b) {
    b.rect(0, 0, 170, 90);
    b.imageBox(10, 10, 60, 60);
    b.word(85, 30, 4);
  }),
  _Entry('List', 'Draw one item, write "xN" beside it', (b) {
    b.rect(0, 0, 130, 50);
    b.word(10, 16, 4);
    b.word(145, 16, 2, size: 14);
  }),
  _Entry(
    'App bar / bottom nav',
    'Band across the top with a title; band at the bottom with 3-5 icons',
    (b) {
      b.word(50, 0, 5);
      b.line(0, 26, 180, 26);
      b.line(0, 70, 180, 70);
      for (final x in [30.0, 90.0, 150.0]) {
        b.ellipse(x, 88, 8, 8);
      }
    },
  ),
  _Entry('FAB', 'Circle with "+" near the bottom-right of the screen', (b) {
    b.ellipse(25, 25, 22, 22);
    b.line(15, 25, 35, 25);
    b.line(25, 15, 25, 35);
  }),
  _Entry('Navigation', 'Arrow from an element to another screen', (b) {
    b.button(0, 30, 80, 36, 3);
    b.arrow(80, 48, 170, 20);
  }),
];

class CheatSheetPage extends StatelessWidget {
  const CheatSheetPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('How to sketch')),
      body: GridView.extent(
        maxCrossAxisExtent: 320,
        childAspectRatio: 1.35,
        padding: const EdgeInsets.all(12),
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        children: [for (final e in _entries) _EntryCard(e)],
      ),
    );
  }
}

class _EntryCard extends StatelessWidget {
  const _EntryCard(this.entry);
  final _Entry entry;

  @override
  Widget build(BuildContext context) {
    final b = SketchBuilder();
    entry.draw(b);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 6,
          children: [
            Expanded(
              child: CustomPaint(
                painter: InkThumbnailPainter(b.doc),
                size: Size.infinite,
              ),
            ),
            Text(entry.name, style: Theme.of(context).textTheme.titleSmall),
            Text(
              entry.how,
              style: Theme.of(context).textTheme.bodySmall,
              maxLines: 2,
            ),
          ],
        ),
      ),
    );
  }
}

/// Draws a document's strokes scaled to fit, preserving aspect ratio.
class InkThumbnailPainter extends CustomPainter {
  const InkThumbnailPainter(this.doc);
  final InkDocument doc;

  @override
  void paint(Canvas canvas, Size size) {
    if (doc.strokes.isEmpty) return;
    final box = doc.strokes
        .map((s) => s.box)
        .reduce((a, b) => a.union(b))
        .inflate(4);
    final s = math.min(size.width / box.w, size.height / box.h);
    canvas.translate(
      (size.width - box.w * s) / 2,
      (size.height - box.h * s) / 2,
    );
    canvas.scale(s);
    canvas.translate(-box.x, -box.y);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2 / s
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xFF1B1B1F);
    for (final st in doc.strokes) {
      final p = Path()..moveTo(st.points.first.x, st.points.first.y);
      for (final q in st.points.skip(1)) {
        p.lineTo(q.x, q.y);
      }
      canvas.drawPath(p, paint);
    }
  }

  @override
  bool shouldRepaint(covariant InkThumbnailPainter old) => old.doc != doc;
}
