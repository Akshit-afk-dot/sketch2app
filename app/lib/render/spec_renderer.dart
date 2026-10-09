/// Live preview: interprets an [AppSpec] directly into Flutter widgets.
///
/// A direct interpreter instead of rfw because the vocabulary is closed (17 node types), we already
/// have a typed model, and the stateful controls/navigation need local widgets either way (DESIGN.md).
/// The widget mapping here must stay identical to lib/export/screen_codegen.dart; the table in
/// DESIGN.md "Spec -> widget mapping" is the shared contract.
library;

import 'package:flutter/material.dart';

import '../spec/spec.dart';
import 'icons.g.dart';
import 'sketch_widgets.dart';

/// Route name of a screen: the first screen is the app's home route.
String routeOf(AppSpec spec, String id) =>
    id == spec.screens.first.id ? '/' : '/$id';

/// Interactive preview of a whole app. Buttons navigate, inputs accept typing.
///
/// It uses its own [Navigator] (so the host app's routes are untouched) and its own [MediaQuery] sized
/// to the preview pane, so `img` heights (a fraction of screen height) look as they will on a phone.
class SpecPreview extends StatelessWidget {
  const SpecPreview({super.key, required this.spec});

  final AppSpec spec;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(size: size),
          child: Theme(
            data: sketchTheme(),
            child: Navigator(
              key: ObjectKey(spec),
              onGenerateRoute: (settings) {
                final screen = spec.screens.firstWhere(
                  (s) => routeOf(spec, s.id) == settings.name,
                  orElse: () => spec.screens.first,
                );
                return MaterialPageRoute<void>(
                  settings: RouteSettings(name: routeOf(spec, screen.id)),
                  builder: (_) => SpecScreenView(spec: spec, screen: screen),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

/// One screen as a [Scaffold] with the spec's appbar, body, bottom navigation and FAB slots.
class SpecScreenView extends StatelessWidget {
  const SpecScreenView({super.key, required this.spec, required this.screen});

  final AppSpec spec;
  final ScreenSpec screen;

  @override
  Widget build(BuildContext context) {
    final r = _NodeRenderer(context, spec);
    final appbar = screen.appbar;
    final nav = screen.bottomnav;
    final fab = screen.fab;
    return Scaffold(
      appBar: appbar == null
          ? null
          : AppBar(
              title: Text(appbar.title),
              actions: [for (final i in appbar.icons) r.build(i)],
            ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: r.build(screen.body),
        ),
      ),
      bottomNavigationBar: nav == null
          ? null
          : NavigationBar(
              selectedIndex: _selectedTab(nav),
              onDestinationSelected: (index) =>
                  goTo(context, r.route(nav.items[index].go), replace: true),
              destinations: [
                for (final item in nav.items)
                  NavigationDestination(
                    icon: Icon(specIcons[item.icon]),
                    label: item.label,
                  ),
              ],
            ),
      floatingActionButton: fab == null
          ? null
          : FloatingActionButton(
              onPressed: r.action(fab.go),
              child: Icon(specIcons[fab.icon]),
            ),
    );
  }

  int _selectedTab(BottomNavSpec nav) {
    final i = nav.items.indexWhere((item) => item.go == screen.id);
    return i < 0 ? 0 : i;
  }
}

class _NodeRenderer {
  _NodeRenderer(this.context, this.spec);

  final BuildContext context;
  final AppSpec spec;

  String? route(String? id) => id == null ? null : routeOf(spec, id);

  /// Every tappable element stays enabled even without a link, so the preview feels like an app.
  VoidCallback action(String? go) =>
      () => goTo(context, route(go));

  Widget build(SpecNode node) => switch (node) {
    ColNode(:final c) => _column(c, 12),
    RowNode(:final c) => Row(
      spacing: 8,
      children: [for (final n in c) _rowChild(n)],
    ),
    CardNode(:final c, :final go) => _card(c, go),
    ListNode(:final n, :final item) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [for (var i = 0; i < n; i++) build(item)],
    ),
    GridNode(:final cols, :final n, :final item) => GridOf(
      columns: cols,
      count: n,
      itemBuilder: (context, index) => build(item),
    ),
    TextNode() => _text(node),
    ParaNode(:final lines) => Paragraph(lines: lines),
    ButtonNode(:final label, :final variant, :final go) => switch (variant) {
      ButtonVariant.primary => FilledButton(
        onPressed: action(go),
        child: Text(label),
      ),
      ButtonVariant.secondary => OutlinedButton(
        onPressed: action(go),
        child: Text(label),
      ),
      ButtonVariant.text => TextButton(
        onPressed: action(go),
        child: Text(label),
      ),
    },
    InputNode(:final label, :final secure, :final multiline) => TextField(
      obscureText: secure,
      minLines: multiline ? 3 : 1,
      maxLines: multiline ? 5 : 1,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    ),
    CheckNode(:final label) => CheckField(label: label),
    RadioNode(:final options) => RadioField(options: options),
    SwitchNode(:final label) => SwitchField(label: label),
    ImageNode(:final h) => PlaceholderImage(heightFactor: h / 100),
    IconNode(:final name, :final go) => IconButton(
      onPressed: action(go),
      icon: Icon(specIcons[name]),
    ),
    AvatarNode(:final go) => _avatar(go),
    DividerNode() => const Divider(),
    SpacerNode() => const SizedBox(height: 24),
  };

  Widget _column(List<SpecNode> c, double spacing) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: spacing,
    children: [for (final n in c) build(n)],
  );

  /// Icons and avatars keep their natural width in a row; everything else shares the space.
  Widget _rowChild(SpecNode n) =>
      n is IconNode || n is AvatarNode ? build(n) : Expanded(child: build(n));

  Widget _card(List<SpecNode> c, String? go) {
    final content = Padding(
      padding: const EdgeInsets.all(12),
      child: _column(c, 8),
    );
    if (go == null) return Card(child: content);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(onTap: action(go), child: content),
    );
  }

  Widget _text(TextNode node) {
    final theme = Theme.of(context).textTheme;
    if (node.s == TextKind.link) {
      return TextButton(onPressed: action(node.go), child: Text(node.v));
    }
    final text = switch (node.s) {
      TextKind.h1 => Text(node.v, style: theme.headlineSmall),
      TextKind.h2 => Text(node.v, style: theme.titleLarge),
      TextKind.caption => Text(node.v, style: theme.bodySmall),
      TextKind.body || TextKind.link => Text(node.v),
    };
    return node.go == null
        ? text
        : InkWell(onTap: action(node.go), child: text);
  }

  Widget _avatar(String? go) {
    const avatar = CircleAvatar(child: Icon(Icons.person));
    if (go == null) return avatar;
    return InkWell(
      onTap: action(go),
      customBorder: const CircleBorder(),
      child: avatar,
    );
  }
}
