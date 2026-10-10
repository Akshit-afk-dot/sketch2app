import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sketch2app/export/project.dart';
import 'package:sketch2app/export/zip.dart';
import 'package:sketch2app/handwriting/handwriting.dart';
import 'package:sketch2app/main.dart';
import 'package:sketch2app/spec/spec.dart';
import 'package:sketch2app/ui/app_settings.dart';
import 'package:sketch2app/ui/code_view.dart';

Future<void> _pumpApp(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    Sketch2App(
      // Rule-based recognizer: deterministic, and the ONNX plugin does not exist in widget tests.
      settings: AppSettings.memory()..useModelRecognizer = false,
      handwriting: const NoHandwritingReader(),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _loadSampleAndConvert(WidgetTester tester) async {
  await tester.tap(find.byType(PopupMenuButton<String>));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Sample: Login -> list (2 screens)'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Convert'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'phone layout: sample sketch -> Convert -> preview navigates to the list',
    (tester) async {
      await _pumpApp(tester, const Size(420, 900));
      expect(
        find.text('Sketch'),
        findsOneWidget,
        reason: 'narrow screens use tabs',
      );
      await _loadSampleAndConvert(tester);
      await tester.tap(find.text('Preview'));
      await tester.pumpAndSettle();
      // No handwriting reader in tests, so labels are the generic fallbacks.
      await tester.tap(find.text('Button'));
      await tester.pumpAndSettle();
      // Without handwriting the second screen's title falls back to its number, and the unreadable
      // "x5" mark stays a single item: navigation is what this test checks.
      expect(find.text('Screen 2'), findsOneWidget);
      expect(find.byType(BackButton), findsOneWidget);
    },
  );

  testWidgets(
    'tablet layout: canvas and preview side by side, code tab shows Dart',
    (tester) async {
      await _pumpApp(tester, const Size(1280, 800));
      expect(find.text('Sketch'), findsNothing);
      await _loadSampleAndConvert(tester);
      expect(
        find.text('Button'),
        findsOneWidget,
        reason: 'preview is visible next to the canvas',
      );
      await tester.tap(find.text('Code'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining(
          'class SketchApp extends StatelessWidget',
          findRichText: true,
        ),
        findsOneWidget,
      );
    },
  );

  test('zip contains every exported file under the package folder', () {
    final spec = parseSpecString(
      '{"v":1,"screens":[{"id":"a","title":"A","body":{"t":"btn","label":"Go"}}]}',
    ).spec!;
    final files = exportProject(spec);
    final archive = ZipDecoder().decodeBytes(
      zipProject(files, rootFolder: 'sketch_app'),
    );
    expect(
      archive.files.map((f) => f.name).toSet(),
      files.keys.map((p) => 'sketch_app/$p').toSet(),
    );
  });

  test('highlighter keeps every character', () {
    const code = "class A extends B { // hi\n  final x = 'q\\'s' + 12; }";
    final spans = highlightDart(
      code,
      ColorScheme.fromSeed(seedColor: Colors.indigo),
    );
    expect(spans.map((s) => s.text).join(), code);
    expect(
      spans.where((s) => s.text == 'class').single.style?.fontWeight,
      FontWeight.w600,
    );
  });
}
