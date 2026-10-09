/// Parse + validate a decoded JSON value into an [AppSpec].
///
/// Hand-written rather than a generic JSON-Schema engine: the vocabulary is closed and small, we need
/// typed nodes anyway, and the issue codes must match ml/s2a/spec/validate.py exactly (checked by the
/// shared fixtures). Structural problems get code `schema`; semantic checks (`dup_id`, `bad_go`,
/// `nesting`, `depth`) only run when the structure is valid, as in Python.
library;

import 'dart:convert';

import 'model.dart';
import 'vocab.dart';

class SpecIssue {
  const SpecIssue(this.code, this.path, this.message);
  final String code;
  final String path;
  final String message;
  @override
  String toString() => '$code at $path: $message';
}

class SpecParseResult {
  const SpecParseResult(this.spec, this.issues);
  final AppSpec? spec;
  final List<SpecIssue> issues;
  bool get isValid => spec != null && issues.isEmpty;
}

/// Parse a JSON string. Malformed JSON is reported as a `json` issue.
SpecParseResult parseSpecString(String source) {
  final Object? decoded;
  try {
    decoded = jsonDecode(source);
  } on FormatException catch (e) {
    return SpecParseResult(null, [SpecIssue('json', '/', e.message)]);
  }
  return parseSpec(decoded);
}

SpecParseResult parseSpec(Object? json) {
  final parser = _Parser();
  final spec = parser.spec(json);
  if (parser.issues.isNotEmpty || spec == null) {
    return SpecParseResult(null, parser.issues);
  }
  final semantic = semanticIssues(spec);
  return SpecParseResult(semantic.isEmpty ? spec : null, semantic);
}

final _idPattern = RegExp(r'^[a-z][a-z0-9_]{0,31}$');
final _controlChar = RegExp(r'[\u0000-\u001F]');

class _Parser {
  final issues = <SpecIssue>[];

  void _fail(String path, String message) =>
      issues.add(SpecIssue('schema', path, message));

  Map<String, Object?>? _object(
    Object? json,
    String path,
    String kind,
    Set<String> required,
  ) {
    if (json is! Map<String, Object?>) {
      _fail(path, 'expected an object');
      return null;
    }
    final allowed = keyOrder[kind]!.toSet();
    var ok = true;
    for (final key in json.keys) {
      if (!allowed.contains(key)) {
        _fail('$path/$key', 'unknown key "$key" for $kind');
        ok = false;
      }
    }
    for (final key in required) {
      if (!json.containsKey(key)) {
        _fail(path, 'missing required key "$key"');
        ok = false;
      }
    }
    return ok ? json : null;
  }

  /// JSON Schema `integer` accepts integral numbers such as 2.0, but never booleans.
  int? _int(Object? v, String path, int min, int max) {
    final int? value = switch (v) {
      final int i => i,
      final double d when d == d.truncateToDouble() && d.isFinite => d.toInt(),
      _ => null,
    };
    if (value == null) {
      _fail(path, 'expected an integer');
      return null;
    }
    if (value < min || value > max) {
      _fail(path, '$value not in [$min, $max]');
      return null;
    }
    return value;
  }

  String? _string(Object? v, String path, int maxLen) {
    if (v is! String) {
      _fail(path, 'expected a string');
      return null;
    }
    final len =
        v.runes.length; // schema lengths count code points, like Python len()
    if (len < 1 || len > maxLen) {
      _fail(path, 'length $len not in [1, $maxLen]');
      return null;
    }
    if (_controlChar.hasMatch(v)) {
      _fail(path, 'control characters are not allowed');
      return null;
    }
    return v;
  }

  String? _label(Object? v, String path) => _string(v, path, 80);

  String? _id(Object? v, String path) {
    if (v is! String || !_idPattern.hasMatch(v)) {
      _fail(path, 'expected an id matching ${_idPattern.pattern}');
      return null;
    }
    return v;
  }

  /// Optional navigation target; returns (present-and-valid value or null, ok flag).
  (String?, bool) _optId(Map<String, Object?> m, String key, String path) {
    if (!m.containsKey(key)) return (null, true);
    final v = _id(m[key], '$path/$key');
    return (v, v != null);
  }

  String? _iconName(Object? v, String path) {
    if (v is! String || !iconNames.contains(v)) {
      _fail(path, 'unknown icon name $v');
      return null;
    }
    return v;
  }

  bool? _bool(Object? v, String path) {
    if (v is! bool) {
      _fail(path, 'expected a boolean');
      return null;
    }
    return v;
  }

  T? _enum<T extends Enum>(Object? v, List<T> values, String path) {
    for (final e in values) {
      if (e.name == v) return e;
    }
    _fail(path, 'expected one of ${values.map((e) => e.name).join('|')}');
    return null;
  }

  List<Object?>? _list(Object? v, String path, int min, int max) {
    if (v is! List<Object?>) {
      _fail(path, 'expected an array');
      return null;
    }
    if (v.length < min || v.length > max) {
      _fail(path, '${v.length} items not in [$min, $max]');
      return null;
    }
    return v;
  }

  AppSpec? spec(Object? json) {
    final m = _object(json, '', 'spec', {'v', 'screens'});
    if (m == null) return null;
    final v = m['v'];
    if (v is! int || v != specVersion) {
      _fail('/v', 'unsupported version $v');
      return null;
    }
    final raw = _list(m['screens'], '/screens', 1, 8);
    if (raw == null) return null;
    final screens = <ScreenSpec>[];
    for (var i = 0; i < raw.length; i++) {
      final s = screen(raw[i], '/screens/$i');
      if (s != null) screens.add(s);
    }
    return screens.length == raw.length ? AppSpec(screens) : null;
  }

  ScreenSpec? screen(Object? json, String path) {
    final m = _object(json, path, 'screen', {'id', 'title', 'body'});
    if (m == null) return null;
    final id = _id(m['id'], '$path/id');
    final title = _string(m['title'], '$path/title', 40);
    final appbar = m.containsKey('appbar')
        ? this.appbar(m['appbar'], '$path/appbar')
        : null;
    final body = node(m['body'], '$path/body');
    final nav = m.containsKey('bottomnav')
        ? bottomnav(m['bottomnav'], '$path/bottomnav')
        : null;
    final fab = m.containsKey('fab') ? this.fab(m['fab'], '$path/fab') : null;
    final slotsOk =
        (!m.containsKey('appbar') || appbar != null) &&
        (!m.containsKey('bottomnav') || nav != null) &&
        (!m.containsKey('fab') || fab != null);
    if (id == null || title == null || body == null || !slotsOk) return null;
    return ScreenSpec(
      id: id,
      title: title,
      appbar: appbar,
      body: body,
      bottomnav: nav,
      fab: fab,
    );
  }

  bool _tagIs(Map<String, Object?> m, String tag, String path) {
    if (m['t'] != tag) {
      _fail('$path/t', 'expected t="$tag"');
      return false;
    }
    return true;
  }

  AppBarSpec? appbar(Object? json, String path) {
    final m = _object(json, path, 'appbar', {'t', 'title'});
    if (m == null || !_tagIs(m, 'appbar', path)) return null;
    final title = _label(m['title'], '$path/title');
    var icons = <IconNode>[];
    var iconsOk = true;
    if (m.containsKey('icons')) {
      final raw = _list(m['icons'], '$path/icons', 1, 4);
      if (raw == null) return null;
      for (var j = 0; j < raw.length; j++) {
        final n = node(raw[j], '$path/icons/$j');
        if (n is IconNode) {
          icons = [...icons, n];
        } else {
          if (n != null) {
            _fail('$path/icons/$j', 'appbar icons must be icon nodes');
          }
          iconsOk = false;
        }
      }
    }
    return title != null && iconsOk ? AppBarSpec(title, icons: icons) : null;
  }

  BottomNavSpec? bottomnav(Object? json, String path) {
    final m = _object(json, path, 'bottomnav', {'t', 'items'});
    if (m == null || !_tagIs(m, 'bottomnav', path)) return null;
    final raw = _list(m['items'], '$path/items', 2, 5);
    if (raw == null) return null;
    final items = <NavItem>[];
    for (var j = 0; j < raw.length; j++) {
      final p = '$path/items/$j';
      final im = _object(raw[j], p, 'navitem', {'icon', 'label'});
      if (im == null) continue;
      final icon = _iconName(im['icon'], '$p/icon');
      final label = _label(im['label'], '$p/label');
      final (go, goOk) = _optId(im, 'go', p);
      if (icon != null && label != null && goOk) {
        items.add(NavItem(icon, label, go: go));
      }
    }
    return items.length == raw.length ? BottomNavSpec(items) : null;
  }

  FabSpec? fab(Object? json, String path) {
    final m = _object(json, path, 'fab', {'t', 'icon'});
    if (m == null || !_tagIs(m, 'fab', path)) return null;
    final icon = _iconName(m['icon'], '$path/icon');
    final (go, goOk) = _optId(m, 'go', path);
    return icon != null && goOk ? FabSpec(icon, go: go) : null;
  }

  List<SpecNode>? _childList(Object? json, String path) {
    final raw = _list(json, path, 1, 40);
    if (raw == null) return null;
    final out = <SpecNode>[];
    for (var j = 0; j < raw.length; j++) {
      final n = node(raw[j], '$path/$j');
      if (n != null) out.add(n);
    }
    return out.length == raw.length ? out : null;
  }

  SpecNode? node(Object? json, String path) {
    if (json is! Map<String, Object?>) {
      _fail(path, 'expected a node object');
      return null;
    }
    final t = json['t'];
    if (t is! String || !bodyTypes.contains(t)) {
      _fail('$path/t', 'unknown node type $t');
      return null;
    }
    const required = <String, Set<String>>{
      'col': {'c'}, 'row': {'c'}, 'card': {'c'}, 'list': {'n', 'item'}, //
      'grid': {'cols', 'n', 'item'},
      'text': {'v'},
      'para': {'lines'},
      'btn': {'label'},
      'input': {'label'},
      'check': {'label'},
      'radio': {'options'},
      'switch': {'label'},
      'img': {'h'}, 'icon': {'name'},
    };
    final m = _object(json, path, t, {'t', ...?required[t]});
    if (m == null) return null;
    final (go, goOk) = _optId(m, 'go', path);
    if (!goOk) return null;

    switch (t) {
      case 'col' || 'row' || 'card':
        final c = _childList(m['c'], '$path/c');
        if (c == null) return null;
        return switch (t) {
          'col' => ColNode(c),
          'row' => RowNode(c),
          _ => CardNode(c, go: go),
        };
      case 'list':
        final n = _int(m['n'], '$path/n', 1, 50);
        final item = node(m['item'], '$path/item');
        return n == null || item == null ? null : ListNode(n, item);
      case 'grid':
        final cols = _int(m['cols'], '$path/cols', 2, 4);
        final n = _int(m['n'], '$path/n', 1, 60);
        final item = node(m['item'], '$path/item');
        return cols == null || n == null || item == null
            ? null
            : GridNode(cols, n, item);
      case 'text':
        final v = _label(m['v'], '$path/v');
        final s = m.containsKey('s')
            ? _enum(m['s'], TextKind.values, '$path/s')
            : TextKind.body;
        return v == null || s == null ? null : TextNode(v, s: s, go: go);
      case 'para':
        final lines = _int(m['lines'], '$path/lines', 1, 12);
        return lines == null ? null : ParaNode(lines);
      case 'btn':
        final label = _label(m['label'], '$path/label');
        final variant = m.containsKey('variant')
            ? _enum(m['variant'], ButtonVariant.values, '$path/variant')
            : ButtonVariant.primary;
        return label == null || variant == null
            ? null
            : ButtonNode(label, variant: variant, go: go);
      case 'input':
        final label = _label(m['label'], '$path/label');
        final secure = m.containsKey('secure')
            ? _bool(m['secure'], '$path/secure')
            : false;
        final multiline = m.containsKey('multiline')
            ? _bool(m['multiline'], '$path/multiline')
            : false;
        return label == null || secure == null || multiline == null
            ? null
            : InputNode(label, secure: secure, multiline: multiline);
      case 'check' || 'switch':
        final label = _label(m['label'], '$path/label');
        if (label == null) return null;
        return t == 'check' ? CheckNode(label) : SwitchNode(label);
      case 'radio':
        final raw = _list(m['options'], '$path/options', 2, 6);
        if (raw == null) return null;
        final options = <String>[];
        for (var j = 0; j < raw.length; j++) {
          final o = _label(raw[j], '$path/options/$j');
          if (o != null) options.add(o);
        }
        return options.length == raw.length ? RadioNode(options) : null;
      case 'img':
        final h = _int(m['h'], '$path/h', 5, 100);
        return h == null ? null : ImageNode(h);
      case 'icon':
        final name = _iconName(m['name'], '$path/name');
        return name == null ? null : IconNode(name, go: go);
      case 'avatar':
        return AvatarNode(go: go);
      case 'divider':
        return const DividerNode();
      case 'spacer':
        return const SpacerNode();
    }
    return null;
  }
}

/// Rules a schema cannot express. Same codes and order of checks as Python's `_semantic_issues`.
List<SpecIssue> semanticIssues(AppSpec spec) {
  final issues = <SpecIssue>[];
  final seen = <String>{};
  for (var i = 0; i < spec.screens.length; i++) {
    final id = spec.screens[i].id;
    if (seen.contains(id)) {
      issues.add(
        SpecIssue('dup_id', '/screens/$i/id', 'duplicate screen id "$id"'),
      );
    }
    seen.add(id);
  }
  for (var i = 0; i < spec.screens.length; i++) {
    final s = spec.screens[i];
    final targets = <String?>[
      ...?s.appbar?.icons.map((e) => e.go),
      for (final n in walk(s.body))
        if (n case Navigable(:final go)) go,
      ...?s.bottomnav?.items.map((e) => e.go),
      s.fab?.go,
    ];
    for (final target in targets) {
      if (target != null && !seen.contains(target)) {
        issues.add(
          SpecIssue(
            'bad_go',
            '/screens/$i',
            'navigation target "$target" is not a screen id',
          ),
        );
      }
    }
    _structure(s.body, '/screens/$i/body', 1, false, issues);
  }
  return issues;
}

void _structure(
  SpecNode node,
  String path,
  int depth,
  bool inRepeat,
  List<SpecIssue> issues,
) {
  if (depth > maxDepth) {
    issues.add(SpecIssue('depth', path, 'nesting deeper than $maxDepth'));
    return;
  }
  final isRepeat = repeatTypes.contains(node.type);
  if (isRepeat && inRepeat) {
    issues.add(
      SpecIssue('nesting', path, '${node.type} inside a repeated item'),
    );
  }
  for (final child in node.children) {
    _structure(child, path, depth + 1, inRepeat || isRepeat, issues);
  }
}
