/// On-device layout model: the fine-tuned Gemma 4 E2B (or Qwen3.5-0.8B) `.litertlm` run by LiteRT-LM
/// through flutter_edge_ai, the Flutter path Google's LiteRT-LM docs point to.
///
/// The model file is not bundled in the APK (it is ~1-2.6 GB); it is pushed once to the app's external
/// files folder with scripts/push_model.ps1, so it works offline and can be swapped without a rebuild.
library;

import 'dart:io';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:path_provider/path_provider.dart';

import 'llm_layout.dart';

/// Where scripts/push_model.ps1 puts the model:
/// /storage/emulated/0/Android/data/dev.sketch2app.sketch2app/files/models/layout.litertlm
Future<File> defaultModelFile() async {
  final dir =
      await getExternalStorageDirectory() ??
      await getApplicationDocumentsDirectory();
  return File('${dir.path}/models/layout.litertlm');
}

class OnDeviceTextGenerator implements TextGenerator {
  OnDeviceTextGenerator({
    this.modelType = ModelType.gemma4,
    this.maxOutputTokens = 1536,
  });

  final ModelType modelType;
  final int maxOutputTokens;
  Future<InferenceModel>? _model;

  @override
  String get name => 'device';

  /// Install (register) the pushed file once and load it; later calls reuse the loaded weights.
  Future<InferenceModel> _load() => _model ??= () async {
    final file = await defaultModelFile();
    if (!file.existsSync()) {
      throw LayoutFailure(
        'no model at ${file.path}; push one with scripts/push_model.ps1',
      );
    }
    await FlutterEdgeAi.installModel(
      modelType: modelType,
      fileType: ModelFileType.litertlm,
    ).fromFile(file.path).install();
    // maxTokens is the whole context window (prompt + answer), not the reply length.
    return FlutterEdgeAi.getActiveModel(maxTokens: 4096);
  }();

  @override
  Future<String> generate(String prompt, {required double temperature}) async {
    final model = await _load();
    final session = await model.createSession(
      temperature: temperature,
      topK: temperature <= 0
          ? 1
          : 40, // topK 1 = greedy decoding for the conservative retry
      maxOutputTokens: maxOutputTokens,
    );
    try {
      await session.addQueryChunk(Message.text(text: prompt, isUser: true));
      return await session.getResponse();
    } finally {
      await session.close();
    }
  }
}
