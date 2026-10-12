/// The learned stroke recognizer running on-device through ONNX Runtime (flutter_onnxruntime).
///
/// Features and decoding are Dart ports verified against Python (test/recognizer_parity_test.dart);
/// only the network itself runs in ONNX Runtime. If the model asset is missing or inference fails,
/// the pipeline falls back to the heuristic recognizer.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import '../diagnostics/run_log.dart';
import '../ink/ink_model.dart';
import '../pipeline/pipeline.dart';
import 'decode.dart';
import 'elements.dart';
import 'features.dart';

const recognizerAsset = 'assets/models/recognizer.onnx';

/// ONNX Runtime options for the recognizers. KleidiAI (Arm's optimised kernels in ORT's CPU backend) is
/// disabled: the first on-device run died inside `session.run` (crash breadcrumbs, 2026-10-12), and
/// KleidiAI's convolution kernels have a known memory blow-up on some Arm64 CPUs (flutter_onnxruntime
/// 1.8.1 changelog, microsoft/onnxruntime#29538); our stroke encoder is convolutional. Two threads are
/// plenty for a 2M-parameter model and keep per-thread scratch memory small.
final sessionOptions = OrtSessionOptions(
  intraOpNumThreads: 2,
  sessionConfigs: {'mlas.disable_kleidiai': '1'},
);

/// Same network fine-tuned on synthetic photos run through the app's vectorizer (lib/photo/).
const photoRecognizerAsset = 'assets/models/recognizer_photo.onnx';
const selfTestAsset = 'assets/selftest/recognizer.json';

class OnnxStrokeRecognizer implements StrokeRecognizer {
  OnnxStrokeRecognizer({
    this.asset = recognizerAsset,
    this.threshold = 0.5,
    this.name = 'model',
  });

  final String asset;
  final double threshold;
  Future<OrtSession>? _session;

  @override
  final String name;

  Future<OrtSession> _open() => _session ??= RunLog.instance.step(
    'onnx session $asset',
    () => OnnxRuntime().createSessionFromAsset(asset, options: sessionOptions),
  );

  /// Raw network outputs (flattened cls, type, affinity) for [doc].
  Future<(List<double>, List<double>, List<double>)> logits(
    InkDocument doc,
  ) async {
    final f = inkFeatures(doc);
    final session = await _open();
    final shape = await OrtValue.fromList(f.shape, [1, f.count, resampleN, 4]);
    final geom = await OrtValue.fromList(f.geom, [1, f.count, geomDim]);
    final out = await RunLog.instance.step(
      'onnx run $asset (${f.count} strokes)',
      () => session.run({'shape': shape, 'geom': geom}),
    );
    try {
      Future<List<double>> read(String k) async => [
        for (final v in await out[k]!.asFlattenedList()) (v as num).toDouble(),
      ];
      return (await read('cls'), await read('type'), await read('affinity'));
    } finally {
      await shape.dispose();
      await geom.dispose();
      for (final v in out.values) {
        await v.dispose();
      }
    }
  }

  @override
  Future<ElementList> recognize(InkDocument doc) async {
    if (doc.strokes.isEmpty) {
      return ElementList(frames: [...doc.frames], elements: [], arrows: []);
    }
    final (cls, type, aff) = await logits(doc);
    // Clustering is cubic in the stroke count (a photo can have hundreds): off the UI thread.
    return RunLog.instance.step(
      'decode (${doc.strokes.length} strokes)',
      () => compute(_decode, (doc, cls, type, aff, threshold)),
    );
  }

  /// On-device parity check: runs the bundled fixture and returns the max |ORT - PyTorch| over all
  /// outputs, plus the inference time in ms.
  Future<({double maxAbsDiff, int millis, int strokes})> selfTest() async {
    final fx =
        jsonDecode(await rootBundle.loadString(selfTestAsset))
            as Map<String, Object?>;
    final doc = InkDocument.fromJson(fx['ink']! as Map<String, Object?>);
    final sw = Stopwatch()..start();
    final (cls, type, aff) = await logits(doc);
    final ms = sw.elapsedMilliseconds;
    List<double> flat(Object? x) => switch (x) {
      final List<Object?> l => [for (final y in l) ...flat(y)],
      final num n => [n.toDouble()],
      _ => const [],
    };
    var worst = 0.0;
    for (final (got, key) in [
      (cls, 'cls'),
      (type, 'type'),
      (aff, 'affinity'),
    ]) {
      final want = flat(fx[key]);
      for (var i = 0; i < want.length; i++) {
        worst = math.max(worst, (got[i] - want[i]).abs());
      }
    }
    return (maxAbsDiff: worst, millis: ms, strokes: doc.strokes.length);
  }

  Future<void> close() async => (await _session)?.close();
}

ElementList _decode(
  (InkDocument, List<double>, List<double>, List<double>, double) a,
) => decodeRecognizer(a.$1, a.$2, a.$3, a.$4, threshold: a.$5);
