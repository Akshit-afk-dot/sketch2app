/// Typed UI spec model. Pure Dart (no Flutter imports) so the exporter and CLI tools can share it.
///
/// Defaults are materialised as typed fields (e.g. [TextKind.body]); `toJson` omits them again, which is
/// exactly what makes the output canonical.
library;

enum TextKind { h1, h2, body, caption, link }

enum ButtonVariant { primary, secondary, text }

sealed class SpecNode {
  const SpecNode();

  String get type;

  /// Canonical JSON map: keys in fixed order, defaults omitted.
  Map<String, Object?> toJson();

  /// Direct children in document order (repeated `item` counts once).
  List<SpecNode> get children => const [];
}

/// Nodes a user can tap to navigate. An interface, not a mixin on [SpecNode], so it does not add a
/// subtype to the sealed hierarchy (switches over [SpecNode] stay exhaustive).
abstract interface class Navigable {
  String? get go;
}

final class ColNode extends SpecNode {
  const ColNode(this.c);
  final List<SpecNode> c;
  @override
  String get type => 'col';
  @override
  List<SpecNode> get children => c;
  @override
  Map<String, Object?> toJson() => {
    't': type,
    'c': [for (final n in c) n.toJson()],
  };
}

final class RowNode extends SpecNode {
  const RowNode(this.c);
  final List<SpecNode> c;
  @override
  String get type => 'row';
  @override
  List<SpecNode> get children => c;
  @override
  Map<String, Object?> toJson() => {
    't': type,
    'c': [for (final n in c) n.toJson()],
  };
}

final class CardNode extends SpecNode implements Navigable {
  const CardNode(this.c, {this.go});
  final List<SpecNode> c;
  @override
  final String? go;
  @override
  String get type => 'card';
  @override
  List<SpecNode> get children => c;
  @override
  Map<String, Object?> toJson() => {
    't': type,
    'go': ?go,
    'c': [for (final n in c) n.toJson()],
  };
}

final class ListNode extends SpecNode {
  const ListNode(this.n, this.item);
  final int n;
  final SpecNode item;
  @override
  String get type => 'list';
  @override
  List<SpecNode> get children => [item];
  @override
  Map<String, Object?> toJson() => {'t': type, 'n': n, 'item': item.toJson()};
}

final class GridNode extends SpecNode {
  const GridNode(this.cols, this.n, this.item);
  final int cols;
  final int n;
  final SpecNode item;
  @override
  String get type => 'grid';
  @override
  List<SpecNode> get children => [item];
  @override
  Map<String, Object?> toJson() => {
    't': type,
    'cols': cols,
    'n': n,
    'item': item.toJson(),
  };
}

final class TextNode extends SpecNode implements Navigable {
  const TextNode(this.v, {this.s = TextKind.body, this.go});
  final String v;
  final TextKind s;
  @override
  final String? go;
  @override
  String get type => 'text';
  @override
  Map<String, Object?> toJson() => {
    't': type,
    'v': v,
    if (s != TextKind.body) 's': s.name,
    'go': ?go,
  };
}

final class ParaNode extends SpecNode {
  const ParaNode(this.lines);
  final int lines;
  @override
  String get type => 'para';
  @override
  Map<String, Object?> toJson() => {'t': type, 'lines': lines};
}

final class ButtonNode extends SpecNode implements Navigable {
  const ButtonNode(this.label, {this.variant = ButtonVariant.primary, this.go});
  final String label;
  final ButtonVariant variant;
  @override
  final String? go;
  @override
  String get type => 'btn';
  @override
  Map<String, Object?> toJson() => {
    't': type,
    'label': label,
    if (variant != ButtonVariant.primary) 'variant': variant.name,
    'go': ?go,
  };
}

final class InputNode extends SpecNode {
  const InputNode(this.label, {this.secure = false, this.multiline = false});
  final String label;
  final bool secure;
  final bool multiline;
  @override
  String get type => 'input';
  @override
  Map<String, Object?> toJson() => {
    't': type,
    'label': label,
    if (secure) 'secure': true,
    if (multiline) 'multiline': true,
  };
}

final class CheckNode extends SpecNode {
  const CheckNode(this.label);
  final String label;
  @override
  String get type => 'check';
  @override
  Map<String, Object?> toJson() => {'t': type, 'label': label};
}

final class RadioNode extends SpecNode {
  const RadioNode(this.options);
  final List<String> options;
  @override
  String get type => 'radio';
  @override
  Map<String, Object?> toJson() => {'t': type, 'options': options};
}

final class SwitchNode extends SpecNode {
  const SwitchNode(this.label);
  final String label;
  @override
  String get type => 'switch';
  @override
  Map<String, Object?> toJson() => {'t': type, 'label': label};
}

final class ImageNode extends SpecNode {
  const ImageNode(this.h);

  /// Height as a percentage of the screen height; keeps the spec resolution-independent.
  final int h;
  @override
  String get type => 'img';
  @override
  Map<String, Object?> toJson() => {'t': type, 'h': h};
}

final class IconNode extends SpecNode implements Navigable {
  const IconNode(this.name, {this.go});
  final String name;
  @override
  final String? go;
  @override
  String get type => 'icon';
  @override
  Map<String, Object?> toJson() => {'t': type, 'name': name, 'go': ?go};
}

final class AvatarNode extends SpecNode implements Navigable {
  const AvatarNode({this.go});
  @override
  final String? go;
  @override
  String get type => 'avatar';
  @override
  Map<String, Object?> toJson() => {'t': type, 'go': ?go};
}

final class DividerNode extends SpecNode {
  const DividerNode();
  @override
  String get type => 'divider';
  @override
  Map<String, Object?> toJson() => {'t': type};
}

final class SpacerNode extends SpecNode {
  const SpacerNode();
  @override
  String get type => 'spacer';
  @override
  Map<String, Object?> toJson() => {'t': type};
}

class AppBarSpec {
  const AppBarSpec(this.title, {this.icons = const []});
  final String title;
  final List<IconNode> icons;
  Map<String, Object?> toJson() => {
    't': 'appbar',
    'title': title,
    if (icons.isNotEmpty) 'icons': [for (final i in icons) i.toJson()],
  };
}

class NavItem {
  const NavItem(this.icon, this.label, {this.go});
  final String icon;
  final String label;
  final String? go;
  Map<String, Object?> toJson() => {'icon': icon, 'label': label, 'go': ?go};
}

class BottomNavSpec {
  const BottomNavSpec(this.items);
  final List<NavItem> items;
  Map<String, Object?> toJson() => {
    't': 'bottomnav',
    'items': [for (final i in items) i.toJson()],
  };
}

class FabSpec {
  const FabSpec(this.icon, {this.go});
  final String icon;
  final String? go;
  Map<String, Object?> toJson() => {'t': 'fab', 'icon': icon, 'go': ?go};
}

class ScreenSpec {
  const ScreenSpec({
    required this.id,
    required this.title,
    required this.body,
    this.appbar,
    this.bottomnav,
    this.fab,
  });
  final String id;
  final String title;
  final AppBarSpec? appbar;
  final SpecNode body;
  final BottomNavSpec? bottomnav;
  final FabSpec? fab;

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'appbar': ?appbar?.toJson(),
    'body': body.toJson(),
    'bottomnav': ?bottomnav?.toJson(),
    'fab': ?fab?.toJson(),
  };
}

class AppSpec {
  const AppSpec(this.screens);
  final List<ScreenSpec> screens;

  ScreenSpec? screen(String id) {
    for (final s in screens) {
      if (s.id == id) return s;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'v': 1,
    'screens': [for (final s in screens) s.toJson()],
  };
}

/// Pre-order traversal of a body tree, including repeated `item` templates once.
Iterable<SpecNode> walk(SpecNode node) sync* {
  yield node;
  for (final child in node.children) {
    yield* walk(child);
  }
}
