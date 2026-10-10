// Render-success check for end-to-end evaluation (ml/s2a/e2e.py): renders every screen of every spec in
// $S2A_RENDER_DIR at phone size and records whether it threw (including layout overflow). Writes
// $S2A_RENDER_DIR/_render.json. Skipped when the variable is not set (normal `flutter test` runs).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sketch2app/render/sketch_widgets.dart';
import 'package:sketch2app/render/spec_renderer.dart';
import 'package:sketch2app/spec/spec.dart';

void main() {
  final dir = Platform.environment['S2A_RENDER_DIR'];
  testWidgets('render every spec in S2A_RENDER_DIR', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final results = <String, Object?>{};
    final files =
        Directory(dir!)
            .listSync()
            .whereType<File>()
            .where(
              (f) =>
                  f.path.endsWith('.json') &&
                  f.uri.pathSegments.last != '_render.json',
            )
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    for (final f in files) {
      final name = f.uri.pathSegments.last;
      final parsed = parseSpecString(f.readAsStringSync());
      if (!parsed.isValid) {
        results[name] = {'valid': false, 'rendered': false};
        continue;
      }
      var ok = true;
      String? error;
      for (final screen in parsed.spec!.screens) {
        await tester.pumpWidget(
          MaterialApp(
            theme: sketchTheme(),
            home: SpecScreenView(spec: parsed.spec!, screen: screen),
          ),
        );
        await tester.pump();
        final e = tester.takeException();
        if (e != null) {
          ok = false;
          error = '$e'.split('\n').first;
        }
      }
      results[name] = {'valid': true, 'rendered': ok, 'error': ?error};
    }
    File('$dir/_render.json').writeAsStringSync(jsonEncode(results));
  }, skip: dir == null);
}
