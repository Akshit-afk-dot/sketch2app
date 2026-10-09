import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sketch2app/render/sketch_widgets.dart';
import 'package:sketch2app/render/spec_renderer.dart';
import 'package:sketch2app/spec/spec.dart';

AppSpec _example(String stem) => parseSpecString(
  File('../spec/examples/$stem.json').readAsStringSync(),
).spec!;

List<String> _exampleStems() =>
    (Directory('../spec/examples')
            .listSync()
            .whereType<File>()
            .map((f) => f.uri.pathSegments.last)
            .toList()
          ..sort())
        .map((n) => n.replaceAll('.json', ''))
        .toList();

/// Phone-sized surface so overflow bugs show up as test failures.
Future<void> _pumpPreview(WidgetTester tester, AppSpec spec) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: SpecPreview(spec: spec)));
  await tester.pumpAndSettle();
}

void main() {
  group('every screen of every example renders without exceptions', () {
    for (final stem in _exampleStems()) {
      testWidgets(stem, (tester) async {
        final spec = _example(stem);
        tester.view.physicalSize = const Size(400, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        for (final screen in spec.screens) {
          await tester.pumpWidget(
            MaterialApp(
              theme: sketchTheme(),
              home: SpecScreenView(spec: spec, screen: screen),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '${screen.id} threw');
        }
      });
    }
  });

  testWidgets('login -> list: Sign in navigates to the list screen', (
    tester,
  ) async {
    await _pumpPreview(tester, _example('10_login_list_nav'));
    expect(find.text('Forgot password?'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Email'), 'a@b.com');
    expect(find.text('a@b.com'), findsOneWidget);
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Item'), findsNWidgets(5));
    // The appbar back button returns to the login screen.
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets('cards, bottom nav and FAB navigate', (tester) async {
    await _pumpPreview(tester, _example('11_shop_3screen'));
    await tester.tap(find.byType(Card).first);
    await tester.pumpAndSettle();
    expect(find.text('Detail'), findsOneWidget);
    await tester.tap(find.text('Add to cart'));
    await tester.pumpAndSettle();
    expect(find.text('Checkout'), findsOneWidget);
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.text('Shop'), findsWidgets);
    await tester.tap(find.widgetWithText(NavigationDestination, 'Cart'));
    await tester.pumpAndSettle();
    expect(find.text('Checkout'), findsOneWidget);
  });

  testWidgets('checkbox, switch and radio keep their state', (tester) async {
    await _pumpPreview(tester, _example('06_settings'));
    await tester.tap(find.text('Share usage data'));
    await tester.tap(find.text('Dark mode'));
    await tester.tap(find.text('Friends'));
    await tester.pump();
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      isTrue,
    );
    expect(
      tester
          .widget<SwitchListTile>(
            find.widgetWithText(SwitchListTile, 'Dark mode'),
          )
          .value,
      isTrue,
    );
    final group = tester.widget<RadioGroup<int>>(find.byType(RadioGroup<int>));
    expect(group.groupValue, 1);
  });

  group('goldens (first screen, 400x800)', () {
    for (final stem in _exampleStems()) {
      testWidgets(stem, (tester) async {
        await _pumpPreview(tester, _example(stem));
        await expectLater(
          find.byType(SpecPreview),
          matchesGoldenFile('goldens/$stem.png'),
        );
      });
    }
  });
}
