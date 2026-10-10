/// Layout by a fine-tuned LLM, with the brief's safety policy:
/// generate -> validate -> repair -> retry at a lower temperature -> (caller) heuristic fallback.
///
/// The generator is pluggable: LAN mode calls the Flask server on the laptop, on-device mode runs
/// LiteRT-LM. Both receive exactly the prompt format the model was trained on (prompt.dart).
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../pipeline/pipeline.dart';
import '../recognize/elements.dart';
import '../spec/spec.dart';
import 'prompt.dart';
import 'repair.dart';

abstract interface class TextGenerator {
  String get name;
  Future<String> generate(String prompt, {required double temperature});
}

class LayoutFailure implements Exception {
  const LayoutFailure(this.message);
  final String message;
  @override
  String toString() => 'LayoutFailure: $message';
}

class LlmLayoutEngine implements LayoutEngine {
  LlmLayoutEngine(this.generator, {this.temperatures = const [0.3, 0.0]});

  final TextGenerator generator;

  /// One attempt per temperature; a lower temperature makes the retry more conservative.
  final List<double> temperatures;

  /// Repairs applied to the last accepted output, and how many attempts it took (debug overlay).
  List<String> lastFixes = const [];
  int lastAttempts = 0;

  @override
  String get name => 'llm:${generator.name}';

  @override
  Future<AppSpec> layout(ElementList elements) async {
    final prompt = buildPrompt(elements);
    final problems = <String>[];
    for (var k = 0; k < temperatures.length; k++) {
      final raw = await generator.generate(
        prompt,
        temperature: temperatures[k],
      );
      final r = repairSpec(raw);
      if (r.spec != null) {
        lastFixes = r.fixes;
        lastAttempts = k + 1;
        return r.spec!;
      }
      problems.add('attempt ${k + 1}: ${r.fixes.join('; ')}');
    }
    throw LayoutFailure(problems.join(' | '));
  }
}

/// LAN mode: the laptop serves the model (ml/s2a/layout/server.py), POST /generate.
class LanTextGenerator implements TextGenerator {
  LanTextGenerator(this.baseUrl, {http.Client? client, this.maxTokens = 1536})
    : _client = client ?? http.Client();

  final String baseUrl;
  final int maxTokens;
  final http.Client _client;

  @override
  String get name => 'lan';

  @override
  Future<String> generate(String prompt, {required double temperature}) async {
    final res = await _client.post(
      Uri.parse('$baseUrl/generate'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'prompt': prompt,
        'temperature': temperature,
        'max_tokens': maxTokens,
      }),
    );
    if (res.statusCode != 200) {
      throw LayoutFailure('server ${res.statusCode}: ${res.body}');
    }
    return (jsonDecode(res.body) as Map<String, Object?>)['output']! as String;
  }
}
