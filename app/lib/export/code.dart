/// Minimal Dart expression IR + pretty printer for the exporter.
///
/// Why an IR instead of string templates: whether an expression may be `const` depends on all of its
/// sub-expressions, and the keyword must appear only at the outermost const-capable node (otherwise
/// `prefer_const_constructors` or `unnecessary_const` fire). Tracking that on a tree is simple; on
/// strings it is error-prone. The printer breaks lines like `dart format`'s tall style: one argument per
/// line with a trailing comma when the flat form does not fit in 80 columns.
library;

sealed class Code {
  const Code();

  /// True when this expression could appear in a const context.
  bool get isConst;
}

/// Verbatim expression, e.g. `Icons.search`, `12`, `'text'`, `Theme.of(context).textTheme.titleLarge`.
final class Raw extends Code {
  const Raw(this.text, {this.isConst = true});
  final String text;
  @override
  final bool isConst;
}

/// Constructor or function invocation. Named `child`/`children` are moved last
/// (lint `sort_child_properties_last`).
final class Call extends Code {
  Call(
    this.callee, {
    this.args = const [],
    List<(String, Code)> named = const [],
    this.constCapable = true,
  }) : named = [
         ...named.where((n) => n.$1 != 'child' && n.$1 != 'children'),
         ...named.where((n) => n.$1 == 'child' || n.$1 == 'children'),
       ];

  final String callee;
  final List<Code> args;
  final List<(String, Code)> named;

  /// False for functions and non-const constructors.
  final bool constCapable;

  @override
  bool get isConst =>
      constCapable &&
      args.every((a) => a.isConst) &&
      named.every((n) => n.$2.isConst);
}

final class ListCode extends Code {
  const ListCode(this.elements);
  final List<Code> elements;
  @override
  bool get isConst => elements.every((e) => e.isConst);
}

/// Collection-for element: `for (var i = 0; i < n; i++) body`.
final class ForElement extends Code {
  const ForElement(this.header, this.body);
  final String header;
  final Code body;
  @override
  bool get isConst => false;
}

/// Function literal `(params) => body`.
final class Closure extends Code {
  const Closure(this.params, this.body);
  final String params;
  final Code body;
  @override
  bool get isConst => false;
}

/// Dart single-quoted string literal for arbitrary user text (labels may contain `'`, `\` or `$`).
Raw str(String s) {
  final b = StringBuffer("'");
  for (final ch in s.split('')) {
    b.write(switch (ch) {
      r'\' => r'\\',
      "'" => r"\'",
      r'$' => r'\$',
      _ => ch,
    });
  }
  b.write("'");
  return Raw(b.toString());
}

const int lineWidth = 80;

/// Print [code] starting at column [col] on a line indented by [indent] spaces. [tail] is the number of
/// characters that will follow on the same line (e.g. `;` or `,`), so the fit check is exact.
String printCode(
  Code code, {
  int indent = 0,
  int col = 0,
  int tail = 0,
  bool inConst = false,
}) {
  final flat = _flat(code, inConst);
  if (col + flat.length + tail <= lineWidth && !flat.contains('\n')) {
    return flat;
  }
  return _broken(code, indent, col, tail, inConst);
}

String _prefix(Code code, bool inConst) {
  final constable = switch (code) {
    Call(:final constCapable) => constCapable,
    ListCode(:final elements) => elements.isNotEmpty,
    _ => false,
  };
  return !inConst && constable && code.isConst ? 'const ' : '';
}

String _flat(Code code, bool inConst) {
  final childConst = inConst || code.isConst;
  final p = _prefix(code, inConst);
  return switch (code) {
    Raw(:final text) => text,
    Call(:final callee, :final args, :final named) =>
      '$p$callee(${[for (final a in args) _flat(a, childConst), for (final (k, v) in named) '$k: ${_flat(v, childConst)}'].join(', ')})',
    ListCode(:final elements) =>
      '$p[${elements.map((e) => _flat(e, childConst)).join(', ')}]',
    ForElement(:final header, :final body) => '$header ${_flat(body, false)}',
    Closure(:final params, :final body) => '$params => ${_flat(body, false)}',
  };
}

String _broken(Code code, int indent, int col, int tail, bool inConst) {
  final childConst = inConst || code.isConst;
  final p = _prefix(code, inConst);
  final inner = ' ' * (indent + 2);
  final close = ' ' * indent;
  switch (code) {
    case Raw(:final text):
      return text;
    case Call(:final callee, :final args, :final named):
      final b = StringBuffer('$p$callee(\n');
      for (final a in args) {
        b.write(
          '$inner${printCode(a, indent: indent + 2, col: indent + 2, tail: 1, inConst: childConst)},\n',
        );
      }
      for (final (k, v) in named) {
        final head = '$k: ';
        b.write(
          '$inner$head${printCode(v, indent: indent + 2, col: indent + 2 + head.length, tail: 1, inConst: childConst)},\n',
        );
      }
      return '$b$close)';
    case ListCode(:final elements):
      final b = StringBuffer('$p[\n');
      for (final e in elements) {
        b.write(
          '$inner${printCode(e, indent: indent + 2, col: indent + 2, tail: 1, inConst: childConst)},\n',
        );
      }
      return '$b$close]';
    case ForElement(:final header, :final body):
      return '$header\n$inner${printCode(body, indent: indent + 2, col: indent + 2, tail: tail)}';
    case Closure(:final params, :final body):
      final head = '$params => ';
      return '$head${printCode(body, indent: indent, col: col + head.length, tail: tail)}';
  }
}
