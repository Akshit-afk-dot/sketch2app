/// Shows the crash-breadcrumb log (lib/diagnostics/run_log.dart) and shares it, so a crash on a phone
/// without USB debugging can still be diagnosed.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../diagnostics/run_log.dart';

class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({super.key});

  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  String _log = RunLog.instance.read();

  Future<void> _share() async {
    final f = File(
      '${(await getTemporaryDirectory()).path}/sketch2app_log.txt',
    );
    await f.writeAsString(_log);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(f.path, mimeType: 'text/plain')],
        subject: 'Sketch2App diagnostics log',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final crashed = RunLog.unfinishedStep(_log);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostics'),
        actions: [
          IconButton(
            tooltip: 'Share log',
            icon: const Icon(Icons.ios_share),
            onPressed: _log.isEmpty ? null : _share,
          ),
          IconButton(
            tooltip: 'Clear log',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => setState(() {
              RunLog.instance.clear();
              _log = RunLog.instance.read();
            }),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (crashed != null)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text('The app closed during: $crashed'),
              ),
            ),
          SelectableText(
            _log.isEmpty ? 'No log yet.' : _log,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ],
      ),
    );
  }
}
