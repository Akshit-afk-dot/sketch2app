/// Canonical serialization: fixed key order, defaults omitted, no whitespace.
///
/// Must be byte-identical to `s2a.spec.canonical_json` in Python; spec/fixtures/canonical holds the
/// expected strings both test suites compare against.
library;

import 'dart:convert';

import 'model.dart';

String canonicalJson(AppSpec spec) => jsonEncode(spec.toJson());
