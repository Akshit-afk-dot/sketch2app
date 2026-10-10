import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../collect/collect_page.dart';
import '../export/project.dart';
import '../export/zip.dart';
import '../layout/llm_layout.dart';
import '../layout/on_device_llm.dart';
import '../handwriting/handwriting.dart';
import '../ink/samples.dart';
import '../pipeline/pipeline.dart';
import '../recognize/onnx_recognizer.dart';
import '../render/spec_renderer.dart';
import 'app_settings.dart';
import 'canvas/sketch_canvas.dart';
import 'canvas/sketch_controller.dart';
import 'code_view.dart';
import 'settings_page.dart';

/// Width from which canvas and preview sit side by side (tablets in landscape, classroom boards).
const double splitBreakpoint = 840;

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.settings,
    required this.handwriting,
  });

  final AppSettings settings;
  final HandwritingReader handwriting;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final controller = SketchController();
  final _onnx = OnnxStrokeRecognizer();
  final _deviceLlm = LlmLayoutEngine(
    OnDeviceTextGenerator(),
  ); // keeps the loaded model between converts
  PipelineResult? _result;
  Map<String, String>? _files;
  String _file = 'lib/main.dart';
  bool _converting = false;
  bool _handwritingMissing = false;
  Timer? _idle;
  int _lastRevision = 0;

  AppSettings get settings => widget.settings;

  @override
  void initState() {
    super.initState();
    controller.stylusOnly = settings.stylusOnly;
    settings.addListener(_onSettings);
    controller.addListener(_onInk);
    unawaited(_checkHandwriting());
  }

  @override
  void dispose() {
    _idle?.cancel();
    settings.removeListener(_onSettings);
    controller.dispose();
    super.dispose();
  }

  Future<void> _checkHandwriting() async {
    bool ready;
    try {
      ready = await widget.handwriting.isReady();
    } on Object {
      ready =
          true; // no plugin on this platform: nothing to download, nothing to nag about
    }
    if (mounted) {
      setState(
        () => _handwritingMissing =
            !ready && widget.handwriting is! NoHandwritingReader,
      );
    }
  }

  void _onSettings() {
    controller.stylusOnly = settings.stylusOnly;
    setState(() {});
  }

  void _onInk() {
    if (controller.revision == _lastRevision) return;
    _lastRevision = controller.revision;
    _idle?.cancel();
    if (settings.autoConvert && controller.doc.strokes.isNotEmpty) {
      _idle = Timer(const Duration(milliseconds: 1500), _convert);
    }
  }

  Future<void> _convert() async {
    if (_converting) return;
    setState(() => _converting = true);
    try {
      final pipeline = Pipeline(
        recognizer: settings.useModelRecognizer
            ? _onnx
            : const HeuristicStrokeRecognizer(),
        handwriting: widget.handwriting,
        layout: switch (settings.layoutMode) {
          'lan' => LlmLayoutEngine(LanTextGenerator(settings.lanUrl)),
          'device' => _deviceLlm,
          _ => const HeuristicLayoutEngine(),
        },
        // The first on-device call also loads the model from storage.
        layoutTimeout: Duration(
          seconds: settings.layoutMode == 'device' ? 90 : 30,
        ),
      );
      final result = await pipeline.run(controller.doc);
      controller.setOverlay(result.elements);
      setState(() {
        _result = result;
        _files = exportProject(result.spec);
        if (!_files!.containsKey(_file)) _file = 'lib/main.dart';
      });
    } on Object catch (e) {
      _snack('Conversion failed: $e');
    } finally {
      if (mounted) setState(() => _converting = false);
    }
  }

  Future<void> _export() async {
    final files = _files;
    if (files == null) {
      _snack('Convert a sketch first');
      return;
    }
    const options = ExportOptions();
    final bytes = zipProject(files, rootFolder: options.packageName);
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/${options.packageName}.zip');
    await file.writeAsBytes(bytes, flush: true);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: 'application/zip')],
        subject: 'Flutter project from Sketch2App',
      ),
    );
  }

  void _snack(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> _downloadHandwriting() async {
    bool ok;
    try {
      ok = await widget.handwriting.prepare();
    } on Object {
      ok = false;
    }
    if (!mounted) return;
    setState(() => _handwritingMissing = !ok);
    _snack(
      ok
          ? 'Handwriting pack ready; works offline now'
          : 'Download failed; check internet',
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= splitBreakpoint;
        return DefaultTabController(
          length: wide ? 2 : 3,
          child: Scaffold(
            appBar: AppBar(
              title: const Text('Sketch2App'),
              actions: _actions(),
              bottom: wide
                  ? null
                  : const TabBar(
                      tabs: [
                        Tab(text: 'Sketch'),
                        Tab(text: 'Preview'),
                        Tab(text: 'Code'),
                      ],
                    ),
            ),
            body: Column(
              children: [
                if (_handwritingMissing)
                  MaterialBanner(
                    content: const Text(
                      'One-time setup: download the English handwriting pack (~20 MB) so labels work offline.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: _downloadHandwriting,
                        child: const Text('Download'),
                      ),
                    ],
                  ),
                Expanded(child: wide ? _wideBody() : _narrowBody()),
              ],
            ),
          ),
        );
      },
    );
  }

  List<Widget> _actions() => [
    FilledButton.icon(
      onPressed: _converting ? null : _convert,
      icon: _converting
          ? const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.auto_awesome),
      label: const Text('Convert'),
    ),
    IconButton(
      tooltip: 'Export Flutter project',
      icon: const Icon(Icons.ios_share),
      onPressed: _export,
    ),
    PopupMenuButton<String>(
      onSelected: (v) {
        switch (v) {
          case 'clear':
            controller.clear();
          case 'removeFrame':
            controller.removeLastFrame();
          case 'collect':
            unawaited(
              Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const CollectPage()),
              ),
            );
          case 'settings':
            unawaited(
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SettingsPage(
                    settings: settings,
                    handwriting: widget.handwriting,
                    recognizer: _onnx,
                  ),
                ),
              ),
            );
          default:
            final sample = sampleSketches.where((s) => s.name == v).firstOrNull;
            if (sample != null) controller.load(sample.build());
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'clear', child: Text('Clear ink')),
        const PopupMenuItem(
          value: 'removeFrame',
          child: Text('Remove last screen'),
        ),
        const PopupMenuDivider(),
        for (final s in sampleSketches)
          PopupMenuItem(value: s.name, child: Text('Sample: ${s.name}')),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'collect',
          child: Text('Collect data (study mode)'),
        ),
        const PopupMenuItem(value: 'settings', child: Text('Settings')),
      ],
    ),
  ];

  /// Drawing tools float on the canvas, next to where the user draws (and keep the app bar short).
  Widget _tools() => Card(
    elevation: 2,
    child: ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Pen',
            isSelected: controller.tool == DrawTool.pen,
            icon: const Icon(Icons.edit_outlined),
            selectedIcon: const Icon(Icons.edit),
            onPressed: () => controller.setTool(DrawTool.pen),
          ),
          IconButton(
            tooltip: 'Eraser',
            isSelected: controller.tool == DrawTool.eraser,
            icon: const Icon(Icons.auto_fix_normal_outlined),
            selectedIcon: const Icon(Icons.auto_fix_normal),
            onPressed: () => controller.setTool(DrawTool.eraser),
          ),
          IconButton(
            tooltip: 'Undo',
            icon: const Icon(Icons.undo),
            onPressed: controller.canUndo ? controller.undo : null,
          ),
          IconButton(
            tooltip: 'Redo',
            icon: const Icon(Icons.redo),
            onPressed: controller.canRedo ? controller.redo : null,
          ),
          IconButton(
            tooltip: 'New screen',
            icon: const Icon(Icons.add_to_queue),
            onPressed: controller.addFrame,
          ),
        ],
      ),
    ),
  );

  Widget _canvas() => Stack(
    children: [
      Positioned.fill(
        child: SketchCanvas(
          controller: controller,
          showOverlay: settings.debugOverlay,
        ),
      ),
      Positioned(left: 8, top: 8, child: _tools()),
      if (settings.debugOverlay && _result != null)
        Positioned(
          left: 8,
          right: 8,
          bottom: 8,
          child: _Timings(result: _result!),
        ),
    ],
  );

  Widget _wideBody() => Row(
    children: [
      Expanded(flex: 3, child: _canvas()),
      const VerticalDivider(width: 1),
      Expanded(
        flex: 2,
        child: Column(
          children: [
            const TabBar(
              tabs: [
                Tab(text: 'Preview'),
                Tab(text: 'Code'),
              ],
            ),
            Expanded(child: TabBarView(children: [_preview(), _code()])),
          ],
        ),
      ),
    ],
  );

  // Swiping between tabs is disabled: on the Sketch tab a horizontal swipe is a stroke.
  Widget _narrowBody() => TabBarView(
    physics: const NeverScrollableScrollPhysics(),
    children: [_canvas(), _preview(), _code()],
  );

  Widget _preview() {
    final spec = _result?.spec;
    if (spec == null) return const _Empty('Sketch a screen, then tap Convert.');
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: AspectRatio(
          aspectRatio: 9 / 19,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(32),
            ),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: SpecPreview(key: ObjectKey(_result), spec: spec),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _code() {
    final files = _files;
    if (files == null) {
      return const _Empty('Generated Flutter code appears here after Convert.');
    }
    final paths = files.keys
        .where(
          (p) =>
              p.startsWith('lib/') ||
              p == 'pubspec.yaml' ||
              p == 'ui_spec.json',
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: DropdownButton<String>(
            value: _file,
            isExpanded: true,
            items: [
              for (final p in paths) DropdownMenuItem(value: p, child: Text(p)),
            ],
            onChanged: (p) => setState(() => _file = p ?? _file),
          ),
        ),
        Expanded(child: CodeView(code: files[_file] ?? '')),
      ],
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyLarge,
      ),
    ),
  );
}

/// Per-stage latency chips (debug overlay).
class _Timings extends StatelessWidget {
  const _Timings({required this.result});
  final PipelineResult result;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 6,
    runSpacing: 6,
    children: [
      for (final t in result.timings)
        Chip(
          visualDensity: VisualDensity.compact,
          backgroundColor: t.fellBack || t.error != null
              ? Colors.amber.shade100
              : null,
          label: Text('$t'),
        ),
      Chip(
        visualDensity: VisualDensity.compact,
        label: Text('total ${result.total.inMilliseconds} ms'),
      ),
    ],
  );
}
