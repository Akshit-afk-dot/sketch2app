import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sketch2app/diagnostics/run_log.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('runlog'));
  tearDown(() => dir.deleteSync(recursive: true));

  test(
    'a step that started and never ended is reported after a crash',
    () async {
      final log = await RunLog.open(dir);
      log.info('app launched (test)');
      await log.step('photo decode', () async => 1);
      // Simulate a native crash inside the recognizer: start written, no end.
      log.info('start convert (478 strokes)');
      log.info('start recognize (photo model)');
      expect(RunLog.unfinishedStep(log.read()), 'recognize (photo model)');
    },
  );

  test(
    'finished and failed steps are not reported; a new launch starts afresh',
    () async {
      final log = await RunLog.open(dir);
      log.info('app launched (test)');
      await log.step('ocr', () async => 'ok');
      await expectLater(
        log.step('vectorize', () async => throw StateError('x')),
        throwsStateError,
      );
      expect(RunLog.unfinishedStep(log.read()), isNull);
      log.info('start layout (heuristic)');
      log.info('app launched (test)');
      expect(RunLog.unfinishedStep(log.read()), isNull);
    },
  );
}
