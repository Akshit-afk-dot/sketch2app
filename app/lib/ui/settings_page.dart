import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../handwriting/handwriting.dart';
import '../layout/on_device_llm.dart';
import '../recognize/onnx_recognizer.dart';
import 'app_settings.dart';
import 'cheat_sheet_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.settings,
    required this.handwriting,
    required this.recognizer,
  });

  final AppSettings settings;
  final HandwritingReader handwriting;
  final OnnxStrokeRecognizer recognizer;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool? _hwReady;
  String? _lanStatus;
  String? _modelPath;
  bool _modelPresent = false;
  late final _lanUrl = TextEditingController(text: widget.settings.lanUrl);
  bool _downloading = false;

  @override
  void initState() {
    super.initState();
    _refresh();
    unawaited(_checkModel());
  }

  Future<void> _refresh() async {
    bool ready;
    try {
      ready = await widget.handwriting.isReady();
    } on Object {
      ready = false; // plugin unavailable on this platform
    }
    if (mounted) setState(() => _hwReady = ready);
  }

  /// Runs the bundled fixture through ONNX Runtime on this device and compares with PyTorch's output.
  Future<void> _selfTest() async {
    String msg;
    try {
      final r = await widget.recognizer.selfTest();
      msg =
          'ONNX Runtime vs PyTorch: max |diff| = ${r.maxAbsDiff.toStringAsExponential(2)} '
          '(${r.strokes} strokes, ${r.millis} ms)';
    } on Object catch (e) {
      msg = 'Self-test failed: $e';
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Recognizer self-test'),
        content: SelectableText(msg),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _checkModel() async {
    try {
      final f = await defaultModelFile();
      final present = f.existsSync();
      if (mounted) {
        setState(() {
          _modelPath = f.path;
          _modelPresent = present;
        });
      }
    } on Object {
      // No external storage (desktop/tests): leave the status unknown.
    }
  }

  Future<void> _testLan() async {
    widget.settings.lanUrl = _lanUrl.text;
    setState(() => _lanStatus = 'Connecting...');
    String status;
    try {
      final r = await http
          .get(Uri.parse('${widget.settings.lanUrl}/health'))
          .timeout(const Duration(seconds: 4));
      status = r.statusCode == 200
          ? 'Connected: ${r.body}'
          : 'HTTP ${r.statusCode}';
    } on Object catch (e) {
      status =
          'Not reachable ($e). Same Wi-Fi? Server started with --host 0.0.0.0?';
    }
    if (mounted) setState(() => _lanStatus = status);
  }

  Future<void> _download() async {
    setState(() => _downloading = true);
    bool ok;
    try {
      ok = await widget.handwriting.prepare();
    } on Object {
      ok = false;
    }
    if (!mounted) return;
    setState(() {
      _downloading = false;
      _hwReady = ok;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Handwriting pack ready (works offline now)'
              : 'Download failed; check internet',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: s,
        builder: (context, _) => ListView(
          children: [
            SwitchListTile(
              title: const Text('Auto-convert'),
              subtitle: const Text('Convert 1.5 s after you stop drawing'),
              value: s.autoConvert,
              onChanged: (v) => s.autoConvert = v,
            ),
            SwitchListTile(
              title: const Text('Stylus only'),
              subtitle: const Text('Fingers pan and zoom; only the pen draws'),
              value: s.stylusOnly,
              onChanged: (v) => s.stylusOnly = v,
            ),
            SwitchListTile(
              title: const Text('Learned recognizer'),
              subtitle: const Text(
                'Off = rule-based recognizer (the baseline; also the automatic fallback)',
              ),
              value: s.useModelRecognizer,
              onChanged: (v) => s.useModelRecognizer = v,
            ),
            SwitchListTile(
              title: const Text('Debug overlay'),
              subtitle: const Text(
                'Recognized boxes on the canvas and per-stage timings',
              ),
              value: s.debugOverlay,
              onChanged: (v) => s.debugOverlay = v,
            ),
            const Divider(),
            ListTile(
              title: const Text('Layout'),
              subtitle: const Text(
                'How the sketch becomes a screen spec; any failure falls back to Rules',
              ),
              trailing: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'rules', label: Text('Rules')),
                  ButtonSegment(value: 'device', label: Text('On-device LLM')),
                  ButtonSegment(value: 'lan', label: Text('LAN LLM')),
                ],
                selected: {s.layoutMode},
                onSelectionChanged: (v) => s.layoutMode = v.first,
              ),
            ),
            if (s.layoutMode == 'lan')
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _lanUrl,
                        decoration: const InputDecoration(
                          labelText: 'Laptop server URL',
                          hintText: 'http://192.168.1.10:8765',
                        ),
                        onSubmitted: (v) => s.lanUrl = v,
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.tonal(
                      onPressed: _testLan,
                      child: const Text('Test'),
                    ),
                  ],
                ),
              ),
            if (s.layoutMode == 'lan' && _lanStatus != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(_lanStatus!),
              ),
            if (s.layoutMode == 'device')
              ListTile(
                leading: Icon(
                  _modelPresent
                      ? Icons.check_circle_outline
                      : Icons.error_outline,
                ),
                title: Text(
                  _modelPresent
                      ? 'Layout model found'
                      : 'No layout model on this device',
                ),
                subtitle: SelectableText(
                  _modelPresent
                      ? (_modelPath ?? '')
                      : 'Push it from the laptop with scripts/push_model.ps1 to ${_modelPath ?? 'the app folder'}',
                ),
              ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.draw_outlined),
              title: const Text('Handwriting pack (English)'),
              subtitle: Text(switch (_hwReady) {
                null => 'Checking...',
                true => 'Installed. Works offline.',
                false =>
                  'Not installed. One-time download (~20 MB) needs internet.',
              }),
              trailing: _downloading
                  ? const SizedBox.square(
                      dimension: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : _hwReady == false
                  ? FilledButton.tonal(
                      onPressed: _download,
                      child: const Text('Download'),
                    )
                  : null,
            ),
            ListTile(
              leading: const Icon(Icons.fact_check_outlined),
              title: const Text('Recognizer self-test'),
              subtitle: const Text(
                'Checks on-device ONNX output against the Python reference',
              ),
              onTap: _selfTest,
            ),
            ListTile(
              leading: const Icon(Icons.help_outline),
              title: const Text('How to sketch (cheat sheet)'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const CheatSheetPage()),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
