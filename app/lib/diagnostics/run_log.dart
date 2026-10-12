/// Crash breadcrumbs: every risky step writes "start" to a small log file, flushed to disk, before it runs,
/// and "end" after. If the app is killed in native code (ONNX Runtime, ML Kit, out of memory), Dart never
/// sees an error, but the next launch finds a step that started and never ended. That pinpoints the crash
/// on a phone without USB debugging; Settings > Diagnostics shows and shares the log.
library;

import 'dart:io';

class RunLog {
  RunLog._(this._file);

  /// No-op log (tests, before [open]).
  RunLog.disabled() : _file = null;

  static RunLog instance = RunLog.disabled();

  final File? _file;
  static const _maxBytes = 64 * 1024;

  /// Opens the log in [dir]; keeps the previous run's lines (trimmed to the last 64 KB) for diagnosis.
  static Future<RunLog> open(Directory dir) async {
    final f = File('${dir.path}/run_log.txt');
    if (f.existsSync() && f.lengthSync() > _maxBytes) {
      final text = f.readAsStringSync();
      f.writeAsStringSync(text.substring(text.length - _maxBytes ~/ 2));
    }
    return instance = RunLog._(f);
  }

  String read() =>
      (_file != null && _file.existsSync()) ? _file.readAsStringSync() : '';

  void clear() {
    if (_file != null && _file.existsSync()) _file.writeAsStringSync('');
  }

  void _write(String line) {
    try {
      _file?.writeAsStringSync(
        '${DateTime.now().toIso8601String()} $line\n',
        mode: FileMode.append,
        flush: true,
      );
    } on Object {
      // Logging must never break the app.
    }
  }

  void info(String message) => _write(message);

  void error(Object error, [StackTrace? stack]) {
    final trace = stack?.toString().split('\n').take(12).join('\n  ') ?? '';
    _write('ERROR $error${trace.isEmpty ? '' : '\n  $trace'}');
  }

  /// Runs [body] between "start [step]" and "end [step]" markers (or "fail [step]: error").
  Future<T> step<T>(String step, Future<T> Function() body) async {
    _write('start $step');
    try {
      final out = await body();
      _write('end $step');
      return out;
    } on Object catch (e) {
      _write('fail $step: $e');
      rethrow;
    }
  }

  /// The step the previous run started but never finished (the app died inside it), else null.
  static String? unfinishedStep(String log) {
    final open = <String>[];
    for (final line in log.split('\n')) {
      final m = RegExp(r'^\S+ (start|end|fail) ([^:]+)').firstMatch(line);
      if (m == null) {
        // Each launch starts afresh: only steps opened since the last launch count.
        if (line.contains(' app launched')) open.clear();
        continue;
      }
      final step = m.group(2)!.trim();
      if (m.group(1) == 'start') {
        open.add(step);
      } else {
        open.remove(step);
      }
    }
    return open.isEmpty ? null : open.last;
  }
}
