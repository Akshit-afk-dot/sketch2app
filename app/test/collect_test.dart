import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sketch2app/collect/collect_plan.dart';
import 'package:sketch2app/ink/ink_model.dart';
import 'package:sketch2app/ink/sketch_builder.dart';
import 'package:sketch2app/spec/spec.dart';

AppSpec _example(String stem) => parseSpecString(
  File('../spec/examples/$stem.json').readAsStringSync(),
).spec!;

void main() {
  test('every shipped collect task parses and has a drawing plan', () {
    final json =
        jsonDecode(File('assets/collect/tasks.json').readAsStringSync())
            as Map<String, Object?>;
    final tasks = (json['tasks']! as List<Object?>)
        .cast<Map<String, Object?>>();
    expect(tasks.length, greaterThanOrEqualTo(30));
    for (final t in tasks) {
      final parsed = parseSpec(t['spec']);
      expect(parsed.issues, isEmpty, reason: '${t['id']}');
      expect(planSteps(parsed.spec!).steps, isNotEmpty, reason: '${t['id']}');
    }
  });

  test(
    'login -> list plan follows the legend and ends with the navigation arrow',
    () {
      final plan = planSteps(_example('10_login_list_nav'));
      final types = plan.groups.map((g) => g.type).toList();
      expect(types.take(6), ['img', 'input', 'input', 'btn', 'text', 'appbar']);
      expect(types, containsAll(['card', 'listmark', 'arrow']));
      expect(plan.steps.last.part, PartKind.arrow);
      expect(plan.steps.last.instruction, contains('"Sign in"'));
      final listmark = plan.groups.firstWhere((g) => g.type == 'listmark');
      expect(listmark.label, 'x5');
    },
  );

  test('record labels every stroke with its element, role and gold text', () {
    final spec = _example('10_login_list_nav');
    final plan = planSteps(spec);
    final b = SketchBuilder()
      ..frame(0, 0)
      ..frame(480, 0);
    final stepStrokes = <List<int>>[];
    for (var k = 0; k < plan.steps.length; k++) {
      final g = plan.groups[plan.steps[k].group];
      final x = g.frame * 480.0 + 20;
      final y = 20.0 + k * 12;
      stepStrokes.add([b.line(x, y, x + 60, y + 4)]);
    }
    final rec = buildRecord(
      id: 'p01_test',
      participant: 'p01',
      taskId: 'ex_10',
      spec: spec,
      plan: plan,
      doc: b.doc,
      stepStrokes: stepStrokes,
    );
    final cls = (rec['stroke_cls']! as List<Object?>).cast<String>();
    final group = (rec['stroke_group']! as List<Object?>).cast<int>();
    expect(cls.length, plan.steps.length);
    expect(group.every((g) => g >= 0), isTrue);
    for (var k = 0; k < plan.steps.length; k++) {
      expect(cls[k], plan.steps[k].part.name);
    }
    final els =
        ((rec['elements']! as Map<String, Object?>)['elements']!
                as List<Object?>)
            .cast<Map<String, Object?>>();
    final btn = els.firstWhere((e) => e['type'] == 'btn');
    expect(btn['text'], 'Sign in');
    expect(
      (btn['strokes']! as List<Object?>).length,
      2,
      reason: 'outline + label',
    );
    expect((btn['text_strokes']! as List<Object?>).length, 1);
    final arrows =
        (rec['elements']! as Map<String, Object?>)['arrows']! as List<Object?>;
    expect(arrows, hasLength(1));
    expect(parseSpec(rec['spec']).isValid, isTrue);
    // Round-trips through JSON as the app saves it.
    expect(
      InkDocument.fromJson(
        jsonDecode(jsonEncode(rec['ink'])) as Map<String, Object?>,
      ).strokes.length,
      cls.length,
    );
  });
}
