/// User settings, persisted with shared_preferences.
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppSettings extends ChangeNotifier {
  AppSettings._(this._prefs);

  static Future<AppSettings> load() async =>
      AppSettings._(await SharedPreferences.getInstance());

  /// In-memory settings for tests and previews.
  AppSettings.memory() : _prefs = null;

  final SharedPreferences? _prefs;
  final _mem = <String, Object>{};

  bool _get(String k, bool fallback) =>
      _prefs?.getBool(k) ?? (_mem[k] as bool?) ?? fallback;

  void _set(String k, bool v) {
    _mem[k] = v;
    _prefs?.setBool(k, v);
    notifyListeners();
  }

  String _getS(String k, String fallback) =>
      _prefs?.getString(k) ?? (_mem[k] as String?) ?? fallback;

  void _setS(String k, String v) {
    _mem[k] = v;
    _prefs?.setString(k, v);
    notifyListeners();
  }

  /// Layout stage: 'rules' (always available), 'lan' (model served by the laptop), 'device' (LiteRT-LM).
  String get layoutMode => _getS('layoutMode', 'rules');
  set layoutMode(String v) => _setS('layoutMode', v);

  /// Base URL of `python -m s2a.layout.server` on the laptop (same Wi-Fi).
  String get lanUrl => _getS('lanUrl', 'http://192.168.1.10:8765');
  set lanUrl(String v) => _setS('lanUrl', v.trim());

  /// Convert automatically after 1.5 s without new ink.
  bool get autoConvert => _get('autoConvert', false);
  set autoConvert(bool v) => _set('autoConvert', v);

  /// Only a stylus draws; fingers pan and zoom.
  bool get stylusOnly => _get('stylusOnly', false);
  set stylusOnly(bool v) => _set('stylusOnly', v);

  /// Use the learned stroke recognizer (ONNX); off = rule-based recognizer (baseline, also the fallback).
  bool get useModelRecognizer => _get('useModelRecognizer', true);
  set useModelRecognizer(bool v) => _set('useModelRecognizer', v);

  /// Show recognized element boxes on the canvas and per-stage timings.
  bool get debugOverlay => _get('debugOverlay', false);
  set debugOverlay(bool v) => _set('debugOverlay', v);
}
