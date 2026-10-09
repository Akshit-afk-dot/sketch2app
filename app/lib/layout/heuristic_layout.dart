/// Rule-based layout: element list -> UI spec. The demo safety net and the baseline for the layout LLM.
///
/// Geometry only: elements are grouped into rows by vertical overlap, nested into the cards that
/// contain them, `xN` marks and identical consecutive items become lists/grids, and arrows become `go`
/// links. The output is valid by construction (checked by tests against the validator).
library;

import 'dart:math' as math;

import '../ink/ink_model.dart';
import '../recognize/elements.dart';
import '../spec/naming.dart';
import '../spec/spec.dart';

class HeuristicLayoutBuilder {
  const HeuristicLayoutBuilder();

  AppSpec build(ElementList list) {
    final frames = [...list.frames]..sort(_readingOrder);
    if (frames.isEmpty) {
      return const AppSpec([
        ScreenSpec(
          id: 'screen',
          title: 'Screen',
          body: ColNode([SpacerNode()]),
        ),
      ]);
    }
    final byFrame = {for (final f in frames) f.id: <SketchElement>[]};
    for (final e in list.elements) {
      final f = e.frame ?? _frameAt(frames, e.box.cx, e.box.cy)?.id;
      if (f != null && byFrame.containsKey(f)) byFrame[f]!.add(e);
    }
    final ids = _screenIds(frames, byFrame);
    final go = _resolveArrows(list.arrows, frames, byFrame, ids);
    return AppSpec([
      for (final f in frames)
        _FrameLayout(f, byFrame[f.id]!, ids[f.id]!, go).screen(),
    ]);
  }

  /// Frames are read like text: rows top to bottom, left to right within a row.
  static int _readingOrder(InkFrame a, InkFrame b) {
    final sameRow =
        (a.box.cy - b.box.cy).abs() < 0.5 * math.min(a.box.h, b.box.h);
    return sameRow ? a.box.x.compareTo(b.box.x) : a.box.y.compareTo(b.box.y);
  }

  static InkFrame? _frameAt(List<InkFrame> frames, double x, double y) {
    for (final f in frames) {
      if (f.box.containsPoint(x, y)) return f;
    }
    return null;
  }

  /// Shared naming rule (lib/spec/naming.dart): app bar title, else first heading, else "Screen k".
  Map<int, ({String id, String title})> _screenIds(
    List<InkFrame> frames,
    Map<int, List<SketchElement>> byFrame,
  ) {
    String? titleOf(List<SketchElement> els) {
      for (final t in [ElementType.appbar, ElementType.heading]) {
        final e =
            els.where((e) => e.type == t && _clean(e.text) != null).toList()
              ..sort((a, b) => a.box.y.compareTo(b.box.y));
        if (e.isNotEmpty) return _clean(e.first.text);
      }
      return null;
    }

    final names = screenNames([
      for (final f in frames) titleOf(byFrame[f.id]!),
    ]);
    return {for (var k = 0; k < frames.length; k++) frames[k].id: names[k]};
  }

  /// Arrow tail -> the smallest element under it (or the nearest one); head -> the frame it points into.
  Map<int, String> _resolveArrows(
    List<SketchArrow> arrows,
    List<InkFrame> frames,
    Map<int, List<SketchElement>> byFrame,
    Map<int, ({String id, String title})> ids,
  ) {
    final go = <int, String>{};
    for (final a in arrows) {
      final from = _frameAt(frames, a.tail.$1, a.tail.$2);
      final to =
          _frameAt(frames, a.head.$1, a.head.$2) ??
          _nearestFrame(frames, a.head);
      if (from == null || to == null || from.id == to.id) continue;
      final u = from.box.w;
      final candidates =
          byFrame[from.id]!
              .where(
                (e) =>
                    e.box.inflate(0.04 * u).containsPoint(a.tail.$1, a.tail.$2),
              )
              .toList()
            ..sort((x, y) => x.box.area.compareTo(y.box.area));
      SketchElement? src = candidates.isEmpty ? null : candidates.first;
      if (src == null) {
        var best = 0.15 * u;
        for (final e in byFrame[from.id]!) {
          final d = math.sqrt(
            math.pow(e.box.cx - a.tail.$1, 2) +
                math.pow(e.box.cy - a.tail.$2, 2),
          );
          if (d < best) {
            best = d;
            src = e;
          }
        }
      }
      if (src != null) go[src.id] = ids[to.id]!.id;
    }
    return go;
  }

  static InkFrame? _nearestFrame(List<InkFrame> frames, (double, double) p) {
    InkFrame? best;
    var bestD = double.infinity;
    for (final f in frames) {
      final dx = math.max(0.0, math.max(f.box.x - p.$1, p.$1 - f.box.right));
      final dy = math.max(0.0, math.max(f.box.y - p.$2, p.$2 - f.box.bottom));
      final d = dx * dx + dy * dy;
      if (d < bestD) {
        bestD = d;
        best = f;
      }
    }
    return best;
  }
}

final _listMark = RegExp(r'^\s*[xX×*]\s*(\d{1,2})\s*$');
final _secret = RegExp(r'pass|pin|secret|otp', caseSensitive: false);

/// Trimmed single-line label limited to the schema's 80 characters, or null if nothing readable.
String? _clean(String? s) {
  if (s == null) return null;
  final t = s
      .replaceAll(RegExp(r'[\u0000-\u001F]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (t.isEmpty) return null;
  return t.runes.length > 80 ? String.fromCharCodes(t.runes.take(80)) : t;
}

class _FrameLayout {
  _FrameLayout(this.frame, this.elements, this.ids, this.go)
    : u = frame.box.w,
      h = frame.box.h;

  final InkFrame frame;
  final List<SketchElement> elements;
  final ({String id, String title}) ids;
  final Map<int, String> go;
  final double u;
  final double h;
  final consumed = <int>{};

  ScreenSpec screen() {
    final appbar = _appbar();
    final nav = _bottomnav();
    final fab = _fab();
    final body = elements.where((e) => !consumed.contains(e.id)).toList();
    final nodes = _arrange(_topLevel(body), body);
    final SpecNode root = switch (nodes) {
      [] => const ColNode([SpacerNode()]),
      [final SpecNode only]
          when only is ColNode || only is ListNode || only is GridNode =>
        only,
      _ => ColNode(nodes.take(40).toList()),
    };
    return ScreenSpec(
      id: ids.id,
      title: ids.title,
      appbar: appbar,
      body: root,
      bottomnav: nav,
      fab: fab,
    );
  }

  // ---------------------------------------------------------------- slots

  AppBarSpec? _appbar() {
    final bars = elements.where((e) => e.type == ElementType.appbar).toList()
      ..sort((a, b) => a.box.y.compareTo(b.box.y));
    if (bars.isEmpty) return null;
    final bar = bars.first;
    consumed.add(bar.id);
    final band = Box.fromLTRB(
      frame.box.x,
      frame.box.y,
      frame.box.right,
      math.max(bar.box.bottom, frame.box.y + 0.06 * h),
    );
    final icons = <IconNode>[];
    for (final e in _inside(band, const {
      ElementType.icon,
      ElementType.menu,
      ElementType.avatar,
    })) {
      consumed.add(e.id);
      if (icons.length < 4) {
        icons.add(
          IconNode(
            e.type == ElementType.menu ? 'menu' : 'circle',
            go: go[e.id],
          ),
        );
      }
    }
    return AppBarSpec(_clean(bar.text) ?? ids.title, icons: icons);
  }

  BottomNavSpec? _bottomnav() {
    final bars = elements
        .where((e) => e.type == ElementType.bottomnav)
        .toList();
    if (bars.isEmpty) return null;
    final bar = bars.first;
    consumed.add(bar.id);
    final band = Box.fromLTRB(
      frame.box.x,
      math.min(bar.box.y, frame.box.bottom - 0.06 * h),
      frame.box.right,
      frame.box.bottom,
    );
    final icons = _inside(band, const {
      ElementType.icon,
      ElementType.menu,
      ElementType.avatar,
    }).toList()..sort((a, b) => a.box.x.compareTo(b.box.x));
    final labels = _inside(band, const {ElementType.text}).toList();
    consumed.addAll([...icons, ...labels].map((e) => e.id));
    final items = <NavItem>[];
    for (final icon in icons.take(5)) {
      final label = labels
          .where((t) => (t.box.cx - icon.box.cx).abs() < 0.12 * u)
          .firstOrNull;
      items.add(
        NavItem(
          'circle',
          _clean(label?.text) ?? defaultNavLabels[items.length],
          go: go[icon.id],
        ),
      );
    }
    if (items.length < 2) {
      return null; // a nav bar needs at least two destinations (schema)
    }
    return BottomNavSpec(items);
  }

  FabSpec? _fab() {
    final fabs = elements.where((e) => e.type == ElementType.fab).toList();
    if (fabs.isEmpty) return null;
    consumed.addAll(fabs.map((e) => e.id));
    return FabSpec('add', go: go[fabs.first.id]);
  }

  Iterable<SketchElement> _inside(Box band, Set<ElementType> types) =>
      elements.where(
        (e) =>
            !consumed.contains(e.id) &&
            types.contains(e.type) &&
            band.containsPoint(e.box.cx, e.box.cy),
      );

  // ---------------------------------------------------------------- body

  /// The card that most tightly contains [e], if any.
  SketchElement? _parentCard(SketchElement e, List<SketchElement> body) {
    SketchElement? best;
    for (final c in body) {
      if (c.id == e.id || c.type != ElementType.card) continue;
      if (c.box.area > e.box.area && c.box.containsPoint(e.box.cx, e.box.cy)) {
        if (best == null || c.box.area < best.box.area) best = c;
      }
    }
    return best;
  }

  List<SketchElement> _topLevel(List<SketchElement> body) =>
      body.where((e) => _parentCard(e, body) == null).toList();

  List<SketchElement> _childrenOf(
    SketchElement card,
    List<SketchElement> body,
  ) => body.where((e) => _parentCard(e, body)?.id == card.id).toList();

  int? _repeatCount(SketchElement e) {
    final m = _listMark.firstMatch(e.text ?? '');
    if (m != null) return int.parse(m.group(1)!).clamp(1, 50);
    return e.type == ElementType.listmark
        ? 3
        : null; // unreadable mark: a small default list
  }

  /// Lay out sibling elements top-to-bottom: rows by vertical overlap, `xN` marks, repetition.
  List<SpecNode> _arrange(
    List<SketchElement> siblings,
    List<SketchElement> body,
  ) {
    final marks = siblings.where((e) => _repeatCount(e) != null).toList();
    final items = siblings.where((e) => _repeatCount(e) == null).toList()
      ..sort((a, b) => a.box.y.compareTo(b.box.y));

    final rows = <List<SketchElement>>[];
    for (final e in items) {
      final row = rows.isEmpty ? null : rows.last;
      if (row != null && _overlapsRow(row, e)) {
        row.add(e);
      } else {
        rows.add([e]);
      }
    }

    final nodes = <SpecNode>[];
    for (var r = 0; r < rows.length; r++) {
      final row = rows[r]..sort((a, b) => a.box.x.compareTo(b.box.x));
      // Legend: "radio = small circle + text"; radios stacked on consecutive rows form one group.
      if (row case [final first] when first.type == ElementType.radio) {
        final group = [first];
        while (r + 1 < rows.length &&
            rows[r + 1].length == 1 &&
            rows[r + 1].single.type == ElementType.radio) {
          group.add(rows[++r].single);
        }
        if (group.length >= 2) {
          nodes.add(
            RadioNode([
              for (final g in group.take(6)) _clean(g.text) ?? 'Option',
            ]),
          );
          continue;
        }
      }
      var node = _rowNode(row, body);
      if (node == null) continue;
      final mark = _markFor(row, marks);
      if (mark != null) {
        marks.remove(mark);
        if (!_containsRepeat(node)) node = ListNode(_repeatCount(mark)!, node);
      }
      nodes.add(node);
    }
    return _collapseRepeats(nodes);
  }

  bool _overlapsRow(List<SketchElement> row, SketchElement e) {
    final top = row.map((r) => r.box.y).reduce(math.min);
    final bottom = row.map((r) => r.box.bottom).reduce(math.max);
    final overlap = math.min(bottom, e.box.bottom) - math.max(top, e.box.y);
    return overlap > 0.5 * math.min(e.box.h, bottom - top);
  }

  /// The `xN` mark written beside this row (to its right, vertically within the row).
  SketchElement? _markFor(List<SketchElement> row, List<SketchElement> marks) {
    final top = row.map((r) => r.box.y).reduce(math.min);
    final bottom = row.map((r) => r.box.bottom).reduce(math.max);
    for (final m in marks) {
      if (m.box.cy >= top - 0.03 * u && m.box.cy <= bottom + 0.03 * u) return m;
    }
    return null;
  }

  SpecNode? _rowNode(List<SketchElement> row, List<SketchElement> body) {
    // Stacked radio circles are one radio group.
    final nodes = [for (final e in row) ?_node(e, body)];
    if (nodes.isEmpty) return null;
    if (nodes.length == 1) return nodes.single;
    // A row of 2-4 identical cards is a grid.
    final sig = _signature(nodes.first);
    if (nodes.length <= 4 &&
        !_containsRepeat(nodes.first) &&
        nodes.every((n) => n is CardNode && _signature(n) == sig)) {
      return GridNode(nodes.length.clamp(2, 4), nodes.length, nodes.first);
    }
    return RowNode(nodes.take(40).toList());
  }

  SpecNode? _node(SketchElement e, List<SketchElement> body) {
    final text = _clean(e.text);
    final link = go[e.id];
    return switch (e.type) {
      ElementType.btn => ButtonNode(text ?? 'Button', go: link),
      ElementType.input => InputNode(
        text ?? 'Input',
        secure: _secret.hasMatch(text ?? ''),
        multiline: e.box.h > 0.15 * u,
      ),
      ElementType.text => TextNode(
        text ?? 'Text',
        s: link != null ? TextKind.link : TextKind.body,
        go: link,
      ),
      ElementType.heading => TextNode(
        text ?? 'Heading',
        s: e.box.h > 0.1 * u ? TextKind.h1 : TextKind.h2,
        go: link,
      ),
      ElementType.para => ParaNode(e.strokes.length.clamp(1, 12)),
      ElementType.img => ImageNode((e.box.h / h * 100).round().clamp(5, 100)),
      ElementType.icon => IconNode('circle', go: link),
      ElementType.menu => IconNode('menu', go: link),
      ElementType.avatar => AvatarNode(go: link),
      ElementType.check => CheckNode(text ?? 'Option'),
      // A lone radio circle is a single yes/no choice; a checkbox expresses that within the schema.
      ElementType.radio => CheckNode(text ?? 'Option'),
      ElementType.toggle => SwitchNode(text ?? 'Setting'),
      ElementType.divider => const DividerNode(),
      ElementType.card => _card(e, body, link),
      ElementType.appbar ||
      ElementType.bottomnav ||
      ElementType.fab ||
      ElementType.listmark => null,
    };
  }

  SpecNode _card(SketchElement card, List<SketchElement> body, String? link) {
    final children = _arrange(_childrenOf(card, body), body);
    // Navigation drawn from anything inside the card makes the whole card tappable.
    final childLink =
        link ??
        _childrenOf(card, body).map((c) => go[c.id]).nonNulls.firstOrNull;
    return CardNode(
      children.isEmpty ? const [SpacerNode()] : children.take(40).toList(),
      go: childLink,
    );
  }

  /// Merge stacked radio checks and consecutive identical nodes into lists (2+ repeated items).
  List<SpecNode> _collapseRepeats(List<SpecNode> nodes) {
    final out = <SpecNode>[];
    var i = 0;
    while (i < nodes.length) {
      final n = nodes[i];
      final sig = _signature(n);
      var j = i + 1;
      while (j < nodes.length && _signature(nodes[j]) == sig) {
        j++;
      }
      final run = j - i;
      // Lists cannot nest (schema `nesting` rule), so an item that already repeats stays as is.
      if (run >= 2 &&
          _repeatable(n) &&
          (n is GridNode || !_containsRepeat(n))) {
        out.add(
          n is GridNode
              ? GridNode(n.cols, (n.n * run).clamp(1, 60), n.item)
              : ListNode(run.clamp(1, 50), n),
        );
      } else {
        out.addAll(nodes.sublist(i, j));
      }
      i = j;
    }
    return out;
  }

  /// Leaf controls that are naturally stacked (inputs, buttons) are not lists even if identical.
  bool _repeatable(SpecNode n) =>
      n is CardNode || n is RowNode || n is GridNode;

  bool _containsRepeat(SpecNode n) =>
      n is ListNode || n is GridNode || n.children.any(_containsRepeat);

  /// Structure with text and links removed: two items "look the same" if their signatures match.
  String _signature(SpecNode n) => switch (n) {
    TextNode(:final s) => 'text:${s.name}',
    ButtonNode(:final variant) => 'btn:${variant.name}',
    InputNode() => 'input',
    CheckNode() => 'check',
    SwitchNode() => 'switch',
    RadioNode() => 'radio',
    ImageNode() => 'img',
    _ => '${n.type}(${n.children.map(_signature).join(',')})',
  };
}
