/// Photo study: the real-world test of photo mode.
///
/// Each task shows a target app (test-split screens, never trained on). The participant draws it on paper
/// following the legend, photographs it, and the app converts the photo exactly as on the home screen
/// (photo model, OCR labels, rule-based layout so runs are comparable). Saved per task: the photo, the
/// target spec and the device's output with timings. `python -m s2a.data.real_photos import <zip>` then
/// scores the device outputs against the targets, and re-runs the photos on the laptop for ablations.
/// No element boxes are drawn by hand: the target spec is the label.
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../handwriting/handwriting.dart';
import '../photo/photo_import.dart';
import '../photo/photo_text.dart';
import '../pipeline/pipeline.dart';
import '../recognize/onnx_recognizer.dart';
import '../render/spec_renderer.dart';
import '../spec/spec.dart';
import 'collect_page.dart' show collectTasksAsset;

Future<Directory> photoStudyDir() async {
  final d = Directory(
    '${(await getApplicationDocumentsDirectory()).path}/photo_study',
  );
  return d.create(recursive: true);
}

class PhotoCollectPage extends StatefulWidget {
  const PhotoCollectPage({super.key, required this.handwriting});

  /// Digital Ink, for labels OCR does not find (same fallback as the home screen).
  final HandwritingReader handwriting;

  @override
  State<PhotoCollectPage> createState() => _PhotoCollectPageState();
}

class _Output {
  const _Output(this.bytes, this.photo, this.result);
  final Uint8List bytes;
  final PhotoSketch photo;
  final PipelineResult result;
}

class _PhotoCollectPageState extends State<PhotoCollectPage> {
  final _recognizer = FirstWorkingRecognizer([
    OnnxStrokeRecognizer(asset: photoRecognizerAsset, name: 'photo model'),
    OnnxStrokeRecognizer(),
  ]);
  List<(String, AppSpec)> _tasks = [];
  int _task = 0;
  String _participant = 'anon';
  int _saved = 0;
  bool _busy = false;
  _Output? _out;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final json =
        jsonDecode(await rootBundle.loadString(collectTasksAsset))
            as Map<String, Object?>;
    final tasks = [
      for (final t
          in (json['tasks']! as List<Object?>).cast<Map<String, Object?>>())
        if (parseSpec(t['spec']) case SpecParseResult(spec: final AppSpec spec))
          (t['id']! as String, spec),
    ];
    final saved = (await photoStudyDir())
        .listSync()
        .where((f) => f.path.endsWith('.json'))
        .length;
    if (!mounted) return;
    setState(() {
      _tasks = tasks;
      _saved = saved;
    });
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
    final clean = (id ?? '').replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
    if (mounted) setState(() => _participant = clean.isEmpty ? 'anon' : clean);
  }

  Future<void> _shoot(ImageSource source) async {
    final file = await ImagePicker().pickImage(
      source: source,
      maxWidth: 2560,
      maxHeight: 2560,
      imageQuality: 95,
    );
    if (file == null) return;
    setState(() => _busy = true);
    try {
      final bytes = await file.readAsBytes();
      final photo = await importPhoto(bytes);
      final result = await Pipeline(
        recognizer: _recognizer,
        handwriting: PhotoTextReader(photo.words, widget.handwriting),
      ).run(photo.result.ink);
      setState(() => _out = _Output(bytes, photo, result));
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not read the photo: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final out = _out;
    if (out == null) return;
    final (taskId, target) = _tasks[_task];
    final id =
        '${_participant}_${taskId}_${DateTime.now().millisecondsSinceEpoch}';
    final dir = await photoStudyDir();
    await File('${dir.path}/$id.jpg').writeAsBytes(out.bytes, flush: true);
    final record = {
      'v': 1,
      'id': id,
      'participant': _participant,
      'task': taskId,
      'photo': '$id.jpg',
      'target': target.toJson(),
      'device': {
        'recognizer': _recognizer.name,
        'layout': 'heuristic',
        'spec': out.result.spec.toJson(),
        'elements': out.result.elements.toJson(),
        'ocr_words': [
          for (final w in out.photo.words)
            {'text': w.text, 'box': w.box.toJson()},
        ],
        'ocr_error': out.photo.ocrError,
        'strokes': out.photo.result.ink.strokes.length,
        'photo_micros': out.photo.micros,
        'stage_ms': {
          for (final t in out.result.timings)
            t.stage: t.elapsed.inMicroseconds / 1000,
        },
        'fell_back': [
          for (final t in out.result.timings)
            if (t.fellBack) t.stage,
        ],
      },
    };
    await File('${dir.path}/$id.json').writeAsString(jsonEncode(record));
    setState(() {
      _saved++;
      _out = null;
      _task = (_task + 1) % _tasks.length;
    });
  }

  Future<void> _export() async {
    final dir = await photoStudyDir();
    final files = dir.listSync().whereType<File>().toList();
    if (files.isEmpty) return;
    final archive = Archive();
    for (final f in files) {
      archive.addFile(
        ArchiveFile.bytes(
          'photo_study/${f.uri.pathSegments.last}',
          await f.readAsBytes(),
        ),
      );
    }
    final zip = File(
      '${(await getTemporaryDirectory()).path}/sketch2app_photo_study.zip',
    );
    await zip.writeAsBytes(ZipEncoder().encodeBytes(archive), flush: true);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(zip.path, mimeType: 'application/zip')],
        subject: 'Sketch2App photo study',
      ),
    );
  }

  Widget _phone(AppSpec spec) => AspectRatio(
    aspectRatio: 9 / 19,
    child: DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.black54, width: 4),
        borderRadius: BorderRadius.circular(20),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: SpecPreview(key: ObjectKey(spec), spec: spec),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final task = _tasks.isEmpty ? null : _tasks[_task];
    final out = _out;
    return Scaffold(
      appBar: AppBar(
        title: Text('Photo study · $_participant · $_saved saved'),
        actions: [
          IconButton(
            tooltip: 'Export photos and results',
            icon: const Icon(Icons.ios_share),
            onPressed: _export,
          ),
        ],
      ),
      body: task == null
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Task ${_task + 1}/${_tasks.length}: draw this app on paper '
                    '(phone outline around each screen, legend from the cheat sheet), '
                    'then photograph it from straight above.',
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            children: [
                              const Text('Target'),
                              Expanded(child: Center(child: _phone(task.$2))),
                            ],
                          ),
                        ),
                        Expanded(
                          child: Column(
                            children: [
                              const Text('From your photo'),
                              Expanded(
                                child: Center(
                                  child: _busy
                                      ? const CircularProgressIndicator()
                                      : out == null
                                      ? const Text('No photo yet')
                                      : _phone(out.result.spec),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      FilledButton.icon(
                        onPressed: _busy
                            ? null
                            : () => _shoot(ImageSource.camera),
                        icon: const Icon(Icons.photo_camera),
                        label: Text(out == null ? 'Take photo' : 'Retake'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _busy
                            ? null
                            : () => _shoot(ImageSource.gallery),
                        icon: const Icon(Icons.photo_library),
                        label: const Text('Gallery'),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: out == null || _busy ? null : _save,
                        icon: const Icon(Icons.check),
                        label: const Text('Save & next'),
                      ),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => setState(() {
                                _out = null;
                                _task = (_task + 1) % _tasks.length;
                              }),
                        child: const Text('Skip'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
    );
  }
}
