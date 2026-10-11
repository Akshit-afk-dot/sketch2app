// Run the app's heuristic stages over many files, so Python evaluation scripts measure exactly the code
// that ships in the app (the baselines in docs/results.md).
//
//   dart run tool/batch.dart recognize <ink_dir> <out_dir>   ink.v1 JSON      -> elements.v1 JSON
//   dart run tool/batch.dart layout    <elem_dir> <out_dir>  elements.v1 JSON -> canonical spec JSON
//   dart run tool/batch.dart vectorize <pgm_dir> <out_dir>   grayscale photo  -> {ink, page, ...} JSON
//
// `vectorize` is how the photo recognizer's training data is made: synthetic photos written by
// ml/s2a/data/photo.py go through the exact code the app runs on a real photo.
//
// Each output file keeps the input's name. A per-file timing report goes to <out_dir>/_timings.json.
import 'dart:convert';
import 'dart:io';

import 'package:sketch2app/ink/ink_model.dart';
import 'package:sketch2app/layout/heuristic_layout.dart';
import 'package:sketch2app/photo/vectorize.dart';
import 'package:sketch2app/recognize/elements.dart';
import 'package:sketch2app/recognize/heuristic_recognizer.dart';
import 'package:sketch2app/spec/spec.dart';

void main(List<String> args) {
  if (args.length != 3 ||
      !{'recognize', 'layout', 'vectorize'}.contains(args[0])) {
    stderr.writeln(
      'usage: dart run tool/batch.dart recognize|layout|vectorize <in_dir> <out_dir>',
    );
    exitCode = 64;
    return;
  }
  final inputs =
      Directory(args[1])
          .listSync()
          .whereType<File>()
          .where(
            (f) => f.path.endsWith(args[0] == 'vectorize' ? '.pgm' : '.json'),
          )
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  final out = Directory(args[2])..createSync(recursive: true);
  final timings = <String, int>{};
  var failures = 0;
  for (final f in inputs) {
    final name = f.uri.pathSegments.last.replaceFirst(
      RegExp(r'\.pgm$'),
      '.json',
    );
    final sw = Stopwatch()..start();
    String result;
    try {
      if (args[0] == 'vectorize') {
        final r = vectorize(
          GrayImage.fromPgm(f.readAsBytesSync()).fitWithin(photoLongSide),
        );
        result = jsonEncode({
          'ink': r.ink.toJson(),
          'page': r.page.toJson(),
          'stroke_width': r.strokeWidth,
          'ink_pixels': r.inkPixels,
          'micros': r.micros,
        });
        timings[name] = sw.elapsedMicroseconds;
        File('${out.path}/$name').writeAsStringSync(result);
        continue;
      }
      final json = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
      result = switch (args[0]) {
        'recognize' => jsonEncode(
          const HeuristicRecognizer()
              .recognize(InkDocument.fromJson(json))
              .toJson(),
        ),
        _ => canonicalJson(
          const HeuristicLayoutBuilder().build(ElementList.fromJson(json)),
        ),
      };
    } on Object catch (e) {
      failures++;
      stderr.writeln('$name: $e');
      continue;
    }
    timings[name] = sw.elapsedMicroseconds;
    File('${out.path}/$name').writeAsStringSync(result);
  }
  File(
    '${out.path}/_timings.json',
  ).writeAsStringSync(jsonEncode({'unit': 'us', 'files': timings}));
  stdout.writeln(
    '${args[0]}: ${inputs.length - failures}/${inputs.length} ok -> ${out.path}',
  );
  if (failures > 0) exitCode = 1;
}
