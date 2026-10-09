import 'package:flutter/material.dart';

import '../handwriting/handwriting.dart';
import 'app_settings.dart';
import 'cheat_sheet_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.settings,
    required this.handwriting,
  });

  final AppSettings settings;
  final HandwritingReader handwriting;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool? _hwReady;
  bool _downloading = false;

  @override
  void initState() {
    super.initState();
    _refresh();
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
              title: const Text('Debug overlay'),
              subtitle: const Text(
                'Recognized boxes on the canvas and per-stage timings',
              ),
              value: s.debugOverlay,
              onChanged: (v) => s.debugOverlay = v,
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
