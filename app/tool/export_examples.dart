// Export every spec in a directory to a Flutter project, then run `flutter analyze` (and optionally
// `flutter test`) on each one. Writes ../docs/results/export_check.json (pass rates for docs/results.md).
//
//   dart run tool/export_examples.dart --out D:/sketch2app-data/exports [--specs ../spec/examples] [--test]
//                                      [--report ../docs/results/export_check.json]
import 'dart:convert';
import 'dart:io';

import 'package:sketch2app/export/project.dart';
import 'package:sketch2app/spec/spec.dart';

Future<ProcessResult> _flutter(List<String> args, String cwd) => Process.run(
  'flutter',
  ['--suppress-analytics', ...args],
  workingDirectory: cwd,
  runInShell: true,
);

Future<void> main(List<String> argv) async {
  String opt(String name, String fallback) {
    final i = argv.indexOf(name);
    return i >= 0 && i + 1 < argv.length ? argv[i + 1] : fallback;
  }

  final specsDir = Directory(opt('--specs', '../spec/examples'));
  final outDir = Directory(opt('--out', 'test/_out/exports'));
  final runTests = argv.contains('--test');
  final reportPath = opt('--report', '../docs/results/export_check.json');
  final specs =
      specsDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  final rows = <Map<String, Object?>>[];
  for (final file in specs) {
    final stem = file.uri.pathSegments.last.replaceAll('.json', '');
    final parsed = parseSpecString(file.readAsStringSync());
    if (!parsed.isValid) {
      rows.add({
        'spec': stem,
        'valid': false,
        'issues': parsed.issues.map((i) => '$i').toList(),
      });
      continue;
    }
    final dir = Directory('${outDir.path}/$stem');
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    for (final MapEntry(key: path, value: content) in exportProject(
      parsed.spec!,
    ).entries) {
      File('${dir.path}/$path')
        ..createSync(recursive: true)
        ..writeAsStringSync(content);
    }
    final pubGet = await _flutter(['pub', 'get', '--offline'], dir.path);
    final analyze = await _flutter(['analyze', '--no-pub'], dir.path);
    final row = <String, Object?>{
      'spec': stem,
      'valid': true,
      'pub_get_ok': pubGet.exitCode == 0,
      'analyze_ok': analyze.exitCode == 0,
      if (analyze.exitCode != 0)
        'analyze_output': '${analyze.stdout}'
            .trim()
            .split('\n')
            .take(30)
            .toList(),
    };
    if (runTests) {
      final t = await _flutter(['test', '--no-pub'], dir.path);
      row['test_ok'] = t.exitCode == 0;
      if (t.exitCode != 0) {
        row['test_output'] = '${t.stdout}${t.stderr}'
            .trim()
            .split('\n')
            .take(30)
            .toList();
      }
    }
    rows.add(row);
    stdout.writeln(
      '$stem: analyze ${row['analyze_ok'] == true ? 'OK' : 'FAIL'}'
      '${runTests ? ', test ${row['test_ok'] == true ? 'OK' : 'FAIL'}' : ''}',
    );
  }

  int count(String key) => rows.where((r) => r[key] == true).length;
  final version = await _flutter(['--version', '--machine'], '.');
  final summary = {
    'projects': rows.length,
    'analyze_pass': count('analyze_ok'),
    if (runTests) 'test_pass': count('test_ok'),
    'flutter': version.exitCode == 0
        ? (jsonDecode('${version.stdout}') as Map)['frameworkVersion']
        : 'unknown',
  };
  final report = File(reportPath)..createSync(recursive: true);
  report.writeAsStringSync(
    const JsonEncoder.withIndent(
      ' ',
    ).convert({'source': specsDir.path, 'summary': summary, 'rows': rows}),
  );
  stdout.writeln(jsonEncode(summary));
  if (summary['analyze_pass'] != rows.length) exitCode = 1;
}
