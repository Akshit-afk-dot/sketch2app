// Cross-language contract: the same fixtures are checked by ml/tests/test_spec.py.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sketch2app/spec/naming.dart';
import 'package:sketch2app/spec/spec.dart';

final specDir = Directory('../spec');

List<File> _jsonFiles(String sub) =>
    (Directory('${specDir.path}/$sub')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path)));

String _name(File f) => f.uri.pathSegments.last;

void main() {
  final valid = [..._jsonFiles('examples'), ..._jsonFiles('fixtures/valid')];
  final invalid = _jsonFiles('fixtures/invalid');

  test('fixture sets are not empty', () {
    expect(valid.length, greaterThanOrEqualTo(10));
    expect(invalid, isNotEmpty);
  });

  test('icon vocabulary matches the JSON Schema', () {
    final schema = jsonDecode(
      File('${specDir.path}/schema/ui_spec.v1.schema.json').readAsStringSync(),
    );
    final defs =
        (schema as Map<String, Object?>)[r'$defs']! as Map<String, Object?>;
    expect((defs['iconName']! as Map<String, Object?>)['enum'], iconNames);
  });

  for (final f in valid) {
    test('valid: ${_name(f)} parses and matches canonical fixture', () {
      final result = parseSpecString(f.readAsStringSync());
      expect(result.issues, isEmpty);
      final expected = File(
        '${specDir.path}/fixtures/canonical/${_name(f)}',
      ).readAsStringSync();
      final canon = canonicalJson(result.spec!);
      expect(
        canon,
        expected.endsWith('\n')
            ? expected.substring(0, expected.length - 1)
            : expected,
      );
      // Canonical form is a fixed point.
      expect(canonicalJson(parseSpecString(canon).spec!), canon);
    });
  }

  for (final f in invalid) {
    final code = _name(f).split('__').first;
    test('invalid: ${_name(f)} reports $code', () {
      final result = parseSpecString(f.readAsStringSync());
      expect(result.spec, isNull);
      expect(result.issues.map((i) => i.code), contains(code));
    });
  }

  test('malformed JSON is a json issue, not a crash', () {
    expect(parseSpecString('{"v":1,').issues.single.code, 'json');
  });

  test('integral doubles are accepted as integers', () {
    final r = parseSpec({
      'v': 1,
      'screens': [
        {
          'id': 'a',
          'title': 'A',
          'body': {'t': 'img', 'h': 20.0},
        },
      ],
    });
    expect(
      canonicalJson(r.spec!),
      '{"v":1,"screens":[{"id":"a","title":"A","body":{"t":"img","h":20}}]}',
    );
  });

  test('screen naming matches the shared fixture', () {
    final fixture =
        jsonDecode(
              File('${specDir.path}/fixtures/naming.json').readAsStringSync(),
            )
            as Map<String, Object?>;
    for (final c in fixture['cases']! as List<Object?>) {
      final m = c! as Map<String, Object?>;
      final titles = (m['titles']! as List<Object?>).cast<String?>();
      expect(screenNames(titles).map((n) => n.id).toList(), m['ids']);
    }
  });
}
