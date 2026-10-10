/// Collect mode UI: classmates sketch target screens one element part at a time.
///
/// Records (same format as synthetic samples) are saved under the app documents folder and exported
/// together as a zip through the share sheet. Only anonymous strokes and a participant code are stored.
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../ink/ink_model.dart';
import '../render/spec_renderer.dart';
import '../spec/spec.dart';
import '../ui/canvas/sketch_canvas.dart';
import '../ui/canvas/sketch_controller.dart';
import 'collect_plan.dart';

const collectTasksAsset = 'assets/collect/tasks.json';

class _Task {
  _Task(this.id, this.spec);
  final String id;
  final AppSpec spec;
}

Future<Directory> collectDir() async {
  final d = Directory(
    '${(await getApplicationDocumentsDirectory()).path}/collect',
  );
  return d.create(recursive: true);
}

class CollectPage extends StatefulWidget {
  const CollectPage({super.key});

  @override
  State<CollectPage> createState() => _CollectPageState();
}

class _CollectPageState extends State<CollectPage> {
  final controller = SketchController();
  List<_Task> _tasks = [];
  int _task = 0;
  CollectPlan? _plan;
  int _step = 0;
  final _stepStrokes = <List<int>>[];
  String? _participant;
  int _saved = 0;

  @override
  void initState() {
    super.initState();
    controller.addListener(_onInk);
    _load();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final json =
        jsonDecode(await rootBundle.loadString(collectTasksAsset))
            as Map<String, Object?>;
    final tasks = <_Task>[
      for (final t
          in (json['tasks']! as List<Object?>).cast<Map<String, Object?>>())
        if (parseSpec(t['spec']) case SpecParseResult(spec: final AppSpec spec))
          _Task(t['id']! as String, spec),
    ];
    final dir = await collectDir();
    final saved = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .length;
    if (!mounted) return;
    setState(() {
      _tasks = tasks;
      _saved = saved;
    });
    await _askParticipant();
    _startTask(0);
  }

  Future<void> _askParticipant() async {
    final text = TextEditingController();
    final id = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Participant code'),
        content: TextField(
          controller: text,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'e.g. p07 (no names)'),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context, text.text.trim()),
            child: const Text('Start'),
          ),
        ],
      ),
    );
    setState(
      () => _participant = (id == null || id.isEmpty)
          ? 'anon'
          : id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), ''),
    );
  }

  void _startTask(int k) {
    if (_tasks.isEmpty) return;
    final task = _tasks[k % _tasks.length];
    final frames = [
      for (var s = 0; s < task.spec.screens.length; s++)
        InkFrame(
          s,
          Box(
            s * (frameSize.width + frameGap),
            0,
            frameSize.width,
            frameSize.height,
          ),
        ),
    ];
    controller
      ..load(InkDocument(frames: frames))
      ..setTool(DrawTool.pen);
    setState(() {
      _task = k % _tasks.length;
      _plan = planSteps(task.spec);
      _step = 0;
      _stepStrokes
        ..clear()
        ..add([]);
    });
  }

  /// Strokes added since the step started belong to the current step.
  void _onInk() {
    final plan = _plan;
    if (plan == null || _step >= plan.steps.length) return;
    final before = _stepStrokes.take(_step).expand((s) => s).toSet();
    final current = [
      for (final s in controller.doc.strokes)
        if (!before.contains(s.id)) s.id,
    ];
    if (current.length != _stepStrokes[_step].length) {
      setState(() => _stepStrokes[_step] = current);
    }
  }

  void _undoStroke() {
    if (_stepStrokes[_step].isNotEmpty) controller.undo();
  }

  Future<void> _next() async {
    final plan = _plan!;
    if (_step + 1 < plan.steps.length) {
      setState(() {
        _step++;
        _stepStrokes.add([]);
      });
      return;
    }
    await _save();
    _startTask(_task + 1);
  }

  Future<void> _save() async {
    final task = _tasks[_task];
    final stamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(RegExp('[^0-9]'), '')
        .substring(0, 14);
    final id = '${_participant}_${task.id}_$stamp';
    final record = buildRecord(
      id: id,
      participant: _participant!,
      taskId: task.id,
      spec: task.spec,
      plan: _plan!,
      doc: controller.doc,
      stepStrokes: _stepStrokes,
    );
    final dir = await collectDir();
    await File('${dir.path}/$id.json').writeAsString(jsonEncode(record));
    setState(() => _saved++);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved ${task.id} ($_saved total)')),
      );
    }
  }

  Future<void> _export() async {
    final dir = await collectDir();
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList();
    if (files.isEmpty) return;
    final archive = Archive();
    for (final f in files) {
      archive.addFile(
        ArchiveFile.bytes(
          'collect/${f.uri.pathSegments.last}',
          await f.readAsBytes(),
        ),
      );
    }
    final zip = File(
      '${(await getTemporaryDirectory()).path}/sketch2app_collect.zip',
    );
    await zip.writeAsBytes(ZipEncoder().encodeBytes(archive), flush: true);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(zip.path, mimeType: 'application/zip')],
        subject: 'Sketch2App collected sketches',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    final task = _tasks.isEmpty ? null : _tasks[_task];
    return Scaffold(
      appBar: AppBar(
        title: Text(
          task == null
              ? 'Collect'
              : 'Collect  ${_task + 1}/${_tasks.length}  ·  $_saved saved',
        ),
        actions: [
          IconButton(
            tooltip: 'Restart this sketch',
            icon: const Icon(Icons.restart_alt),
            onPressed: () => _startTask(_task),
          ),
          IconButton(
            tooltip: 'Skip this target',
            icon: const Icon(Icons.skip_next),
            onPressed: () => _startTask(_task + 1),
          ),
          IconButton(
            tooltip: 'Export collected sketches',
            icon: const Icon(Icons.ios_share),
            onPressed: _export,
          ),
        ],
      ),
      body: plan == null || task == null
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(
              builder: (context, c) {
                final step = plan.steps[_step];
                final canNext = _stepStrokes[_step].isNotEmpty;
                final instructions = Material(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Text(
                          'Step ${_step + 1}/${plan.steps.length}',
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            step.instruction,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Undo last stroke',
                          icon: const Icon(Icons.undo),
                          onPressed: canNext ? _undoStroke : null,
                        ),
                        FilledButton(
                          onPressed: canNext ? _next : null,
                          child: Text(
                            _step + 1 == plan.steps.length ? 'Finish' : 'Next',
                          ),
                        ),
                      ],
                    ),
                  ),
                );
                final target = Padding(
                  padding: const EdgeInsets.all(12),
                  child: AspectRatio(
                    aspectRatio: 9 / 19,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.black26),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: SpecPreview(
                          key: ObjectKey(task),
                          spec: task.spec,
                        ),
                      ),
                    ),
                  ),
                );
                final canvas = SketchCanvas(controller: controller);
                if (c.maxWidth >= 840) {
                  return Column(
                    children: [
                      instructions,
                      Expanded(
                        child: Row(
                          children: [
                            Expanded(child: canvas),
                            SizedBox(width: c.maxWidth * 0.28, child: target),
                          ],
                        ),
                      ),
                    ],
                  );
                }
                return Column(
                  children: [
                    instructions,
                    SizedBox(height: c.maxHeight * 0.3, child: target),
                    Expanded(child: canvas),
                  ],
                );
              },
            ),
    );
  }
}
