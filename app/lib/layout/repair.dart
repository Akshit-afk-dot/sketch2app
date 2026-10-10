/// Turn raw LLM text into a valid spec when possible: extract, fix JSON syntax, then fix the structure.
///
/// Small models fail in predictable ways: prose or code fences around the JSON, a missing closing
/// bracket after hitting the token limit, a trailing comma, an unknown key, a one-option radio, a link
/// to a screen that does not exist. Each fix is recorded so the debug overlay and the evaluation can
/// report how often repair was needed. Anything not fixable returns null and the caller falls back.
library;

import 'dart:convert';

import '../spec/spec.dart';

class RepairResult {
  const RepairResult(this.spec, this.fixes);
  final AppSpec? spec;
  final List<String> fixes;
}

/// Close brackets left open when generation stopped early (string-aware scan).
String _balance(String s) {
  final stack = <String>[];
  var inString = false, escaped = false;
  for (final ch in s.split('')) {
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch == r'\') {
        escaped = true;
      } else if (ch == '"') {
        inString = false;
      }
      continue;
    }
    switch (ch) {
      case '"':
        inString = true;
      case '{':
        stack.add('}');
      case '[':
        stack.add(']');
      case '}' || ']':
        if (stack.isNotEmpty) stack.removeLast();
    }
  }
  var out = s;
  if (inString) out += '"';
  out = out.replaceAll(RegExp(r',\s*$'), '');
  return out + stack.reversed.join();
}

Object? _decodeLenient(String raw, List<String> fixes) {
  final start = raw.indexOf('{');
  if (start < 0) return null;
  final end = raw.lastIndexOf('}');
  var text = end > start ? raw.substring(start, end + 1) : raw.substring(start);
  if (start > 0 || end < raw.trimRight().length - 1) {
    fixes.add('stripped text around JSON');
  }
  for (var attempt = 0; attempt < 3; attempt++) {
    try {
      return jsonDecode(text);
    } on FormatException {
      if (attempt == 0) {
        // replaceAllMapped: Dart's replaceAll would insert a literal "$1".
        final noTrailing = text.replaceAllMapped(
          RegExp(r',\s*([}\]])'),
          (m) => m[1]!,
        );
        if (noTrailing != text) {
          fixes.add('removed trailing commas');
          text = noTrailing;
          continue;
        }
      }
      // Generation cut off mid-object: drop the dangling tail after the last complete value, then close.
      final cut = text.lastIndexOf(RegExp(r'[}\]"0-9el]'));
      final balanced = _balance(cut > 0 ? text.substring(0, cut + 1) : text);
      if (balanced == text) return null;
      fixes.add('closed unbalanced brackets');
      text = balanced;
    }
  }
  return null;
}

const _maxChildren = 40;

/// Structural repair on decoded JSON: keep what is valid, drop what is not.
Object? _fixNode(
  Object? n,
  List<String> fixes, {
  bool inRepeat = false,
  int depth = 1,
}) {
  if (n is! Map<String, Object?> || depth > maxDepth) return null;
  final t = n['t'];
  if (t is! String || !bodyTypes.contains(t)) {
    fixes.add('dropped node of unknown type $t');
    return null;
  }
  final allowed = keyOrder[t]!.toSet();
  final out = <String, Object?>{
    for (final e in n.entries)
      if (allowed.contains(e.key)) e.key: e.value,
  };
  if (out.length != n.length) fixes.add('dropped unknown keys on $t');
  List<Object?> kids(Object? c) => [
    for (final k in (c is List<Object?> ? c : const <Object?>[]))
      ?_fixNode(
        k,
        fixes,
        inRepeat: inRepeat || repeatTypes.contains(t),
        depth: depth + 1,
      ),
  ];
  switch (t) {
    case 'col' || 'row' || 'card':
      final c = kids(out['c']).take(_maxChildren).toList();
      if (c.isEmpty) return null;
      out['c'] = c;
    case 'list' || 'grid':
      final item = _fixNode(
        out['item'],
        fixes,
        inRepeat: true,
        depth: depth + 1,
      );
      if (item == null) return null;
      if (inRepeat) {
        fixes.add('unwrapped nested $t');
        return item;
      }
      out['item'] = item;
    case 'radio':
      final opts = (out['options'] is List<Object?>)
          ? (out['options']! as List<Object?>).whereType<String>().toList()
          : <String>[];
      if (opts.length < 2) {
        fixes.add('radio with < 2 options became a checkbox');
        return opts.isEmpty ? null : {'t': 'check', 'label': opts.first};
      }
      out['options'] = opts.take(6).toList();
  }
  return out;
}

RepairResult repairSpec(String raw) {
  final fixes = <String>[];
  final decoded = _decodeLenient(raw, fixes);
  if (decoded == null) return RepairResult(null, [...fixes, 'not JSON']);
  final direct = parseSpec(decoded);
  if (direct.isValid) return RepairResult(direct.spec, fixes);

  if (decoded is! Map<String, Object?> ||
      decoded['screens'] is! List<Object?>) {
    return RepairResult(null, [...fixes, 'no screens']);
  }
  final screens = <Map<String, Object?>>[];
  final ids = <String>{};
  for (final s in (decoded['screens']! as List<Object?>).take(8)) {
    if (s is! Map<String, Object?>) continue;
    final body = _fixNode(s['body'], fixes);
    if (body == null) continue;
    var id = s['id'] is String
        ? s['id']! as String
        : 'screen${screens.length + 1}';
    id = id.toLowerCase().replaceAll(RegExp('[^a-z0-9_]'), '_');
    if (id.isEmpty || !RegExp('^[a-z]').hasMatch(id)) id = 's_$id';
    while (ids.contains(id)) {
      id = '${id}_2';
    }
    ids.add(id);
    screens.add({
      'id': id,
      'title': s['title'] is String && (s['title']! as String).isNotEmpty
          ? s['title']
          : 'Screen ${screens.length + 1}',
      if (s['appbar'] is Map<String, Object?>) 'appbar': s['appbar'],
      'body': body,
      if (s['bottomnav'] is Map<String, Object?>) 'bottomnav': s['bottomnav'],
      if (s['fab'] is Map<String, Object?>) 'fab': s['fab'],
    });
  }
  if (screens.isEmpty) {
    return RepairResult(null, [...fixes, 'no usable screens']);
  }
  var candidate = <String, Object?>{'v': 1, 'screens': screens};
  // Slots and links that still fail validation are dropped one kind at a time.
  for (final drop in ['bad_go', 'slots']) {
    final r = parseSpec(candidate);
    if (r.isValid) return RepairResult(r.spec, fixes);
    candidate = jsonDecode(jsonEncode(candidate)) as Map<String, Object?>;
    if (drop == 'bad_go') {
      fixes.add('removed links to missing screens');
      _dropLinks(candidate, ids);
    } else {
      fixes.add('dropped invalid app bar / bottom nav / fab');
      for (final s
          in (candidate['screens']! as List<Object?>)
              .cast<Map<String, Object?>>()) {
        for (final slot in ['appbar', 'bottomnav', 'fab']) {
          if (s.containsKey(slot) && !_slotValid(slot, s[slot])) s.remove(slot);
        }
      }
    }
  }
  final r = parseSpec(candidate);
  return RepairResult(
    r.isValid ? r.spec : null,
    r.isValid ? fixes : [...fixes, ...r.issues.map((i) => '$i')],
  );
}

void _dropLinks(Object? n, Set<String> ids) {
  if (n is Map<String, Object?>) {
    if (n['go'] is String && !ids.contains(n['go'])) n.remove('go');
    for (final v in n.values) {
      _dropLinks(v, ids);
    }
  } else if (n is List<Object?>) {
    for (final v in n) {
      _dropLinks(v, ids);
    }
  }
}

/// Is this app bar / bottom nav / FAB structurally valid on its own? Links are ignored here (they were
/// checked against the real screen ids already).
bool _slotValid(String slot, Object? value) {
  final copy = jsonDecode(jsonEncode(value));
  _dropLinks(copy, const {});
  final probe = {
    'v': 1,
    'screens': [
      {
        'id': 'x',
        'title': 'x',
        'body': {'t': 'spacer'},
        slot: copy,
      },
    ],
  };
  return parseSpec(probe).isValid;
}
