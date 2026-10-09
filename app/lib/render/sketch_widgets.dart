// Small widgets shared by the live preview and every exported project.
//
// The exporter copies this file verbatim into generated apps as lib/sketch_widgets.dart (a test keeps
// the embedded copy in sync), so preview and export behave identically. It must only import
// package:flutter/material.dart.
import 'package:flutter/material.dart';

/// Theme used by the preview and by exported apps.
ThemeData sketchTheme() => ThemeData(colorSchemeSeed: Colors.indigo);

/// Navigate to a named route; `null` means the element has no link. With [replace] (tab bars), tapping
/// the current tab is a no-op instead of stacking a copy of the same screen.
void goTo(BuildContext context, String? route, {bool replace = false}) {
  if (route == null) return;
  final navigator = Navigator.of(context);
  if (replace) {
    if (ModalRoute.of(context)?.settings.name == route) return;
    navigator.pushReplacementNamed(route);
  } else {
    navigator.pushNamed(route);
  }
}

/// Grey box standing in for an image; height is a fraction of the screen height, as sketched.
class PlaceholderImage extends StatelessWidget {
  const PlaceholderImage({super.key, required this.heightFactor});

  final double heightFactor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: MediaQuery.sizeOf(context).height * heightFactor,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(Icons.image_outlined, color: scheme.onSurfaceVariant),
    );
  }
}

/// Placeholder body text with a fixed number of lines.
class Paragraph extends StatelessWidget {
  const Paragraph({super.key, required this.lines});

  final int lines;

  static const _lorem =
      'Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor '
      'incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud '
      'exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure '
      'dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. '
      'Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt '
      'mollit anim id est laborum.';

  @override
  Widget build(BuildContext context) {
    return Text(
      List.filled(3, _lorem).join(' '),
      maxLines: lines,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// Fixed-column grid that sizes rows to their content (GridView would force a cell aspect ratio).
class GridOf extends StatelessWidget {
  const GridOf({
    super.key,
    required this.columns,
    required this.count,
    required this.itemBuilder,
  });

  final int columns;
  final int count;
  final IndexedWidgetBuilder itemBuilder;

  @override
  Widget build(BuildContext context) {
    final rows = (count + columns - 1) ~/ columns;
    return Column(
      spacing: 8,
      children: [
        for (var r = 0; r < rows; r++)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 8,
            children: [
              for (var c = 0; c < columns; c++)
                Expanded(
                  child: r * columns + c < count
                      ? itemBuilder(context, r * columns + c)
                      : const SizedBox.shrink(),
                ),
            ],
          ),
      ],
    );
  }
}

/// Labelled checkbox that remembers its own state.
class CheckField extends StatefulWidget {
  const CheckField({super.key, required this.label});

  final String label;

  @override
  State<CheckField> createState() => _CheckFieldState();
}

class _CheckFieldState extends State<CheckField> {
  bool _checked = false;

  @override
  Widget build(BuildContext context) {
    return CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      title: Text(widget.label),
      value: _checked,
      onChanged: (value) => setState(() => _checked = value ?? false),
    );
  }
}

/// Labelled switch that remembers its own state.
class SwitchField extends StatefulWidget {
  const SwitchField({super.key, required this.label});

  final String label;

  @override
  State<SwitchField> createState() => _SwitchFieldState();
}

class _SwitchFieldState extends State<SwitchField> {
  bool _on = false;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(widget.label),
      value: _on,
      onChanged: (value) => setState(() => _on = value),
    );
  }
}

/// Group of mutually exclusive options.
class RadioField extends StatefulWidget {
  const RadioField({super.key, required this.options});

  final List<String> options;

  @override
  State<RadioField> createState() => _RadioFieldState();
}

class _RadioFieldState extends State<RadioField> {
  int? _selected;

  @override
  Widget build(BuildContext context) {
    return RadioGroup<int>(
      groupValue: _selected,
      onChanged: (value) => setState(() => _selected = value),
      child: Column(
        children: [
          for (var i = 0; i < widget.options.length; i++)
            RadioListTile<int>(
              contentPadding: EdgeInsets.zero,
              value: i,
              title: Text(widget.options[i]),
            ),
        ],
      ),
    );
  }
}
