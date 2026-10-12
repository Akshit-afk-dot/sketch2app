import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:path_provider/path_provider.dart';

import 'diagnostics/run_log.dart';

import 'handwriting/handwriting.dart';
import 'ui/app_settings.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  String? crashedIn;
  try {
    final log = await RunLog.open(await getApplicationDocumentsDirectory());
    crashedIn = RunLog.unfinishedStep(log.read());
    log.info(
      'app launched (${Platform.operatingSystem} ${Platform.operatingSystemVersion})',
    );
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      log.error(details.exceptionAsString(), details.stack);
      previous?.call(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      log.error(error, stack);
      return false;
    };
  } on Object {
    // No documents directory (some tests/desktop setups): run without breadcrumbs.
  }
  final settings = await AppSettings.load();
  if (Platform.isAndroid) {
    // LiteRT-LM runs the on-device layout model; registering it costs nothing until a model is loaded.
    await FlutterEdgeAi.initialize(inferenceEngines: const [LiteRtLmEngine()]);
  }
  // ML Kit exists only on Android/iOS; elsewhere the pipeline runs with generic labels.
  final HandwritingReader handwriting = Platform.isAndroid || Platform.isIOS
      ? MlKitHandwritingReader()
      : const NoHandwritingReader();
  runApp(
    Sketch2App(
      settings: settings,
      handwriting: handwriting,
      crashedIn: crashedIn,
    ),
  );
}

class Sketch2App extends StatelessWidget {
  const Sketch2App({
    super.key,
    required this.settings,
    required this.handwriting,
    this.crashedIn,
  });

  final AppSettings settings;
  final HandwritingReader handwriting;

  /// The step the previous run died in (from the crash breadcrumbs), shown once as a banner.
  final String? crashedIn;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sketch2App',
      theme: ThemeData(colorSchemeSeed: Colors.deepPurple),
      home: HomePage(
        settings: settings,
        handwriting: handwriting,
        crashedIn: crashedIn,
      ),
    );
  }
}
