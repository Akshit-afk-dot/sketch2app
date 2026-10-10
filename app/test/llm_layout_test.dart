import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sketch2app/ink/ink_model.dart';
import 'package:sketch2app/layout/llm_layout.dart';
import 'package:sketch2app/layout/repair.dart';
import 'package:sketch2app/recognize/elements.dart';
import 'package:sketch2app/spec/spec.dart';

const _good =
    '{"v":1,"screens":[{"id":"login","title":"Login","body":{"t":"col","c":[{"t":"btn","label":"Go","go":"home"}]}},'
    '{"id":"home","title":"Home","body":{"t":"text","v":"Hi"}}]}';

class _Scripted implements TextGenerator {
  _Scripted(this.outputs);
  final List<String> outputs;
  final temps = <double>[];
  @override
  String get name => 'scripted';
  @override
  Future<String> generate(String prompt, {required double temperature}) async {
    temps.add(temperature);
    return outputs[temps.length - 1];
  }
}

ElementList _elements() => ElementList(
  frames: [const InkFrame(0, Box(0, 0, 360, 720))],
  elements: [
    SketchElement(
      id: 0,
      type: ElementType.btn,
      box: const Box(20, 300, 320, 50),
      frame: 0,
      text: 'Go',
    ),
  ],
  arrows: const [],
);

void main() {
  group('repair', () {
    test('valid output passes untouched', () {
      final r = repairSpec(_good);
      expect(r.spec, isNotNull);
      expect(r.fixes, isEmpty);
    });

    test('prose and code fences around the JSON', () {
      final r = repairSpec('Here is the spec:\n```json\n$_good\n```');
      expect(canonicalJson(r.spec!), _good);
      expect(r.fixes, contains('stripped text around JSON'));
    });

    test('generation cut off at the token limit', () {
      final cut = _good.substring(0, _good.length - 30);
      final r = repairSpec(cut);
      expect(r.spec, isNotNull, reason: r.fixes.join('; '));
      expect(r.fixes, contains('closed unbalanced brackets'));
    });

    test(
      'trailing commas, unknown keys, one-option radio, link to a missing screen',
      () {
        const raw =
            '{"v":1,"screens":[{"id":"a","title":"A","body":{"t":"col","c":['
            '{"t":"btn","label":"Go","color":"red","go":"nowhere"},{"t":"radio","options":["Only"]},]}}]}';
        final r = repairSpec(raw);
        expect(r.spec, isNotNull, reason: r.fixes.join('; '));
        expect(
          canonicalJson(r.spec!),
          '{"v":1,"screens":[{"id":"a","title":"A","body":{"t":"col","c":[{"t":"btn","label":"Go"},{"t":"check","label":"Only"}]}}]}',
        );
      },
    );

    test('hopeless output returns null', () {
      expect(repairSpec('I cannot help with that.').spec, isNull);
      expect(repairSpec('{"v":1,"screens":[]}').spec, isNull);
    });
  });

  group('LLM layout engine', () {
    test('valid first answer is used at the first temperature', () async {
      final gen = _Scripted([_good]);
      final engine = LlmLayoutEngine(gen);
      final spec = await engine.layout(_elements());
      expect(spec.screens, hasLength(2));
      expect(gen.temps, [0.3]);
      expect(engine.lastAttempts, 1);
    });

    test('garbage first answer -> retry at a lower temperature', () async {
      final gen = _Scripted(['nonsense', _good]);
      final spec = await LlmLayoutEngine(gen).layout(_elements());
      expect(spec.screens.first.id, 'login');
      expect(gen.temps, [0.3, 0.0]);
    });

    test(
      'all attempts fail -> LayoutFailure so the pipeline falls back to rules',
      () async {
        final engine = LlmLayoutEngine(_Scripted(['nope', 'still nope']));
        expect(() => engine.layout(_elements()), throwsA(isA<LayoutFailure>()));
      },
    );
  });

  test(
    'LAN client posts the trained prompt format and reads the output',
    () async {
      late Map<String, Object?> sent;
      final client = MockClient((req) async {
        sent = jsonDecode(req.body) as Map<String, Object?>;
        return http.Response(jsonEncode({'output': _good, 'ms': 12}), 200);
      });
      final gen = LanTextGenerator('http://laptop:8765', client: client);
      final spec = await LlmLayoutEngine(gen).layout(_elements());
      expect(spec.screens, hasLength(2));
      expect(sent['prompt'], startsWith('Convert these sketch elements'));
      expect(sent['prompt'], contains('1 btn 6,42,89,7 "Go"'));
      expect(sent['temperature'], 0.3);
    },
  );
}
