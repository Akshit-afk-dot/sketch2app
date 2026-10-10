// The app must send the layout model exactly the text format it was trained on (ml/s2a/layout/prompt.py).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sketch2app/layout/prompt.dart';
import 'package:sketch2app/recognize/elements.dart';

void main() {
  final files =
      Directory('../spec/fixtures/prompt').listSync().whereType<File>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  test('fixtures exist', () => expect(files, isNotEmpty));
  for (final f in files) {
    test('prompt matches Python: ${f.uri.pathSegments.last}', () {
      final fx = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
      final el = ElementList.fromJson(fx['elements']! as Map<String, Object?>);
      expect(buildPrompt(el), fx['prompt']);
    });
  }
}
