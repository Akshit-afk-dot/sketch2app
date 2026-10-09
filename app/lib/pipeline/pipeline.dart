/// Sketch -> spec pipeline with per-stage timings and a fallback at every ML stage.
///
/// Every stage is an interface with a deterministic heuristic implementation, so a model that is
/// missing, slow or wrong degrades the result instead of breaking the demo. Timings feed the debug
/// overlay and the latency table in docs/results.md.
library;

import 'dart:async';

import '../handwriting/handwriting.dart';
import '../ink/ink_model.dart';
import '../layout/heuristic_layout.dart';
import '../recognize/elements.dart';
import '../recognize/heuristic_recognizer.dart';
import '../spec/spec.dart';

abstract interface class StrokeRecognizer {
  String get name;
  Future<ElementList> recognize(InkDocument doc);
}

abstract interface class LayoutEngine {
  String get name;
  Future<AppSpec> layout(ElementList elements);
}

class HeuristicStrokeRecognizer implements StrokeRecognizer {
  const HeuristicStrokeRecognizer();
  @override
  String get name => 'heuristic';
  @override
  Future<ElementList> recognize(InkDocument doc) async =>
      const HeuristicRecognizer().recognize(doc);
}

class HeuristicLayoutEngine implements LayoutEngine {
  const HeuristicLayoutEngine();
  @override
  String get name => 'heuristic';
  @override
  Future<AppSpec> layout(ElementList elements) async =>
      const HeuristicLayoutBuilder().build(elements);
}

class StageTiming {
  const StageTiming(
    this.stage,
    this.engine,
    this.elapsed, {
    this.fellBack = false,
    this.error,
  });
  final String stage;
  final String engine;
  final Duration elapsed;
  final bool fellBack;
  final String? error;

  @override
  String toString() =>
      '$stage[$engine${fellBack ? ' (fallback)' : ''}] ${elapsed.inMilliseconds} ms';
}

class PipelineResult {
  const PipelineResult(this.elements, this.spec, this.timings);
  final ElementList elements;
  final AppSpec spec;
  final List<StageTiming> timings;
  Duration get total => timings.fold(Duration.zero, (a, t) => a + t.elapsed);
}

class Pipeline {
  Pipeline({
    this.recognizer = const HeuristicStrokeRecognizer(),
    this.handwriting = const NoHandwritingReader(),
    this.layout = const HeuristicLayoutEngine(),
    this.layoutTimeout = const Duration(seconds: 30),
  });

  final StrokeRecognizer recognizer;
  final HandwritingReader handwriting;
  final LayoutEngine layout;
  final Duration layoutTimeout;

  static const _recognizerFallback = HeuristicStrokeRecognizer();
  static const _layoutFallback = HeuristicLayoutEngine();

  Future<PipelineResult> run(InkDocument doc) async {
    final timings = <StageTiming>[];

    final elements = await _stage(
      'recognize',
      recognizer.name,
      () => recognizer.recognize(doc),
      fallbackName: _recognizerFallback.name,
      fallback: identical(recognizer, _recognizerFallback)
          ? null
          : () => _recognizerFallback.recognize(doc),
      timings: timings,
    );

    final sw = Stopwatch()..start();
    String? hwError;
    try {
      await readElementTexts(handwriting, elements, {
        for (final s in doc.strokes) s.id: s,
      });
    } on Object catch (e) {
      hwError =
          '$e'; // unreadable labels fall back to generic ones in the layout stage
    }
    timings.add(
      StageTiming(
        'handwriting',
        handwriting.runtimeType.toString(),
        sw.elapsed,
        error: hwError,
      ),
    );

    final spec = await _stage(
      'layout',
      layout.name,
      () => layout.layout(elements).timeout(layoutTimeout),
      fallbackName: _layoutFallback.name,
      fallback: identical(layout, _layoutFallback)
          ? null
          : () => _layoutFallback.layout(elements),
      timings: timings,
    );
    return PipelineResult(elements, spec, timings);
  }

  Future<T> _stage<T>(
    String stage,
    String engine,
    Future<T> Function() primary, {
    required String fallbackName,
    required Future<T> Function()? fallback,
    required List<StageTiming> timings,
  }) async {
    final sw = Stopwatch()..start();
    try {
      final out = await primary();
      timings.add(StageTiming(stage, engine, sw.elapsed));
      return out;
    } on Object catch (e) {
      if (fallback == null) rethrow;
      final out = await fallback();
      timings.add(
        StageTiming(
          stage,
          fallbackName,
          sw.elapsed,
          fellBack: true,
          error: '$engine: $e',
        ),
      );
      return out;
    }
  }
}
