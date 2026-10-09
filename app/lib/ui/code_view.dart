/// Read-only Dart code view with lightweight syntax highlighting.
///
/// A ~60-line regex tokenizer instead of a package: `flutter_highlight` is unmaintained (last release
/// 2021, pre-Dart-3), and generated code only needs keywords, strings, comments, numbers and types.
library;

import 'package:flutter/material.dart';

final _token = RegExp(
  r'(?<comment>//[^\n]*)'
  r"|(?<string>'(?:\\.|[^'\\])*')"
  r'|(?<number>\b\d+(?:\.\d+)?\b)'
  r'|(?<keyword>\b(?:import|class|extends|const|final|return|void|if|else|for|var|super|this|true|false|null|required|static|async|await|in)\b)'
  r'|(?<annotation>@\w+)'
  r'|(?<type>\b[A-Z]\w*\b)',
);

/// Splits [code] into styled spans. Pure function so it can be unit-tested.
List<TextSpan> highlightDart(String code, ColorScheme scheme) {
  final styles = {
    'comment': TextStyle(color: scheme.outline, fontStyle: FontStyle.italic),
    'string': const TextStyle(color: Color(0xFF2E7D32)),
    'number': const TextStyle(color: Color(0xFFAD1457)),
    'keyword': TextStyle(color: scheme.primary, fontWeight: FontWeight.w600),
    'annotation': const TextStyle(color: Color(0xFF8D6E63)),
    'type': const TextStyle(color: Color(0xFF00838F)),
  };
  final spans = <TextSpan>[];
  var last = 0;
  for (final m in _token.allMatches(code)) {
    if (m.start > last) {
      spans.add(TextSpan(text: code.substring(last, m.start)));
    }
    final kind = styles.keys.firstWhere((k) => m.namedGroup(k) != null);
    spans.add(TextSpan(text: m.group(0), style: styles[kind]));
    last = m.end;
  }
  if (last < code.length) spans.add(TextSpan(text: code.substring(last)));
  return spans;
}

class CodeView extends StatelessWidget {
  const CodeView({super.key, required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surfaceContainerLowest,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SelectableText.rich(
            TextSpan(
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12.5,
                height: 1.4,
              ),
              children: highlightDart(code, scheme),
            ),
          ),
        ),
      ),
    );
  }
}
