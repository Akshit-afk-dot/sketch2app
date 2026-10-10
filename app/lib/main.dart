import 'dart:io';

import 'package:flutter/material.dart';

import 'handwriting/handwriting.dart';
import 'ui/app_settings.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await AppSettings.load();
  // ML Kit exists only on Android/iOS; elsewhere the pipeline runs with generic labels.
  final HandwritingReader handwriting = Platform.isAndroid || Platform.isIOS
      ? MlKitHandwritingReader()
      : const NoHandwritingReader();
  runApp(Sketch2App(settings: settings, handwriting: handwriting));
}

class Sketch2App extends StatelessWidget {
  const Sketch2App({
    super.key,
    required this.settings,
    required this.handwriting,
  });

  final AppSettings settings;
  final HandwritingReader handwriting;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sketch2App',
      theme: ThemeData(colorSchemeSeed: Colors.deepPurple),
      home: HomePage(settings: settings, handwriting: handwriting),
    );
  }
}
