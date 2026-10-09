import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sketch2app/export/code.dart';
import 'package:sketch2app/export/project.dart';
import 'package:sketch2app/export/screen_codegen.dart';
import 'package:sketch2app/spec/spec.dart';

import '../tool/gen.dart' as gen;

AppSpec _example(String stem) => parseSpecString(
  File('../spec/examples/$stem.json').readAsStringSync(),
).spec!;

void main() {
  test('export is deterministic', () {
    final spec = _example('11_shop_3screen');
    expect(exportProject(spec), exportProject(_example('11_shop_3screen')));
  });

  test('project contains app, screens, tests, android and the source spec', () {
    final files = exportProject(_example('10_login_list_nav'));
    expect(
      files.keys,
      containsAll([
        'pubspec.yaml',
        'analysis_options.yaml',
        'lib/main.dart',
        'lib/sketch_widgets.dart',
        'lib/screens/login_screen.dart',
        'lib/screens/home_screen.dart',
        'test/widget_test.dart',
        'android/app/src/main/AndroidManifest.xml',
        'android/app/src/main/kotlin/com/example/sketch_app/MainActivity.kt',
        'ui_spec.json',
      ]),
    );
    expect(
      files['ui_spec.json']!.trim(),
      canonicalJson(_example('10_login_list_nav')),
    );
    expect(
      files['lib/main.dart'],
      contains("'/home': (context) => const HomeScreen(),"),
    );
    expect(
      files['lib/screens/login_screen.dart'],
      contains("goTo(context, '/home')"),
    );
  });

  test('AppBar is never emitted as const (it has no const constructor)', () {
    final screen = exportProject(
      _example('02_signup'),
    )['lib/screens/signup_screen.dart']!;
    expect(screen, contains('appBar: AppBar('));
    expect(screen, isNot(contains('const AppBar')));
  });

  test('user text is escaped into valid Dart string literals', () {
    expect(str(r"It's $5 \ ok").text, r"'It\'s \$5 \\ ok'");
    expect(str('Café 👋').text, "'Café 👋'");
  });

  test('const goes on the outermost const-capable node only', () {
    final code = Call(
      'Padding',
      named: [
        ('padding', Call('EdgeInsets.all', args: [const Raw('8')])),
        ('child', Call('Text', args: [str('x')])),
      ],
    );
    expect(
      printCode(code),
      "const Padding(padding: EdgeInsets.all(8), child: Text('x'))",
    );
    final mixed = Call(
      'Column',
      named: [
        (
          'children',
          ListCode([
            Call('Text', args: [str('a')]),
            Call('goTo', constCapable: false),
          ]),
        ),
      ],
    );
    expect(printCode(mixed), "Column(children: [const Text('a'), goTo()])");
  });

  test('long expressions break one argument per line with trailing commas', () {
    final code = Call(
      'Text',
      args: [str('a' * 70)],
      named: [
        (
          'style',
          const Raw('Theme.of(context).textTheme.titleLarge', isConst: false),
        ),
      ],
    );
    expect(
      printCode(code),
      "Text(\n  '${'a' * 70}',\n  style: Theme.of(context).textTheme.titleLarge,\n)",
    );
  });

  test('screen ids map to Dart names', () {
    expect(screenClassName('order_detail'), 'OrderDetailScreen');
    expect(screenFileName('order_detail'), 'order_detail_screen.dart');
  });

  test('generated files are up to date (run: dart run tool/gen.dart)', () {
    expect(File(gen.iconsOut).readAsStringSync(), gen.iconsSource());
    final widgets = File(
      gen.widgetsSourceIn,
    ).readAsStringSync().replaceAll('\r\n', '\n');
    expect(
      File(gen.widgetsSourceOut).readAsStringSync(),
      gen.widgetsSourceConstant(widgets),
    );
  });
}
