/// Collect mode: target spec -> drawing steps, and finished drawing -> labelled sample.
///
/// The participant draws one part of one element per step (an outline, then its label) and taps Next,
/// so every stroke's element (grouping label) and role (text / shape / arrow) are known exactly. The
/// saved record has the same shape as a synthetic training sample (ml/s2a/data/synth.py), so training
/// and evaluation code read real sketches unchanged. Pure Dart: unit-tested without a device.
library;

import '../ink/ink_model.dart';
import '../spec/spec.dart';

enum PartKind { shape, text, arrow }

class CollectStep {
  const CollectStep(this.group, this.part, this.instruction);
  final int group;
  final PartKind part;
  final String instruction;
}

class CollectGroup {
  CollectGroup(this.kind, this.type, this.frame, {this.label});
  final String kind; // element | arrow
  final String type; // elements.v1 type, or 'arrow'
  final int frame;
  final String? label;
  String? arrowFrom; // arrows: what to start from
  int? arrowTo; // arrows: target screen index
}

class CollectPlan {
  final groups = <CollectGroup>[];
  final steps = <CollectStep>[];

  int _group(String type, int frame, {String? label}) {
    groups.add(CollectGroup('element', type, frame, label: label));
    return groups.length - 1;
  }

  void _step(int g, PartKind part, String instruction) =>
      steps.add(CollectStep(g, part, instruction));
}

String _q(String s) => '"$s"';

/// Steps in reading order, following the sketch legend (the in-app cheat sheet) for every type.
CollectPlan planSteps(AppSpec spec) {
  final plan = CollectPlan();
  final links = <(String, String, int)>[]; // (description, target id, screen)

  void link(String? go, String what, int screen) {
    if (go != null) links.add((what, go, screen));
  }

  void node(SpecNode n, int s) {
    switch (n) {
      case ColNode(:final c) || RowNode(:final c):
        for (final k in c) {
          node(k, s);
        }
      case CardNode(:final c, :final go):
        final g = plan._group('card', s);
        plan._step(
          g,
          PartKind.shape,
          'Card: draw a rectangle big enough for what goes inside it',
        );
        link(go, 'the card', s);
        for (final k in c) {
          node(k, s);
        }
      case ListNode(:final n, :final item):
        node(item, s);
        final g = plan._group('listmark', s, label: 'x$n');
        plan._step(
          g,
          PartKind.text,
          'List: write ${_q('x$n')} beside the item you just drew',
        );
      case GridNode(:final cols, :final n, :final item):
        for (var k = 0; k < cols; k++) {
          node(item, s);
        }
        if (n > cols) {
          final g = plan._group('listmark', s, label: 'x$n');
          plan._step(
            g,
            PartKind.text,
            'Grid: write ${_q('x$n')} beside the row',
          );
        }
      case TextNode(:final v, s: final style, :final go):
        if (style == TextKind.h1 || style == TextKind.h2) {
          final g = plan._group('heading', s, label: v);
          plan._step(g, PartKind.text, 'Heading: write ${_q(v)}');
          plan._step(g, PartKind.shape, 'Underline the heading');
        } else {
          final g = plan._group('text', s, label: v);
          plan._step(g, PartKind.text, 'Text: write ${_q(v)}');
        }
        link(go, _q(v), s);
      case ParaNode(:final lines):
        final g = plan._group('para', s);
        plan._step(
          g,
          PartKind.shape,
          'Paragraph: draw $lines wavy line${lines == 1 ? '' : 's'}',
        );
      case ButtonNode(:final label, :final go):
        final g = plan._group('btn', s, label: label);
        plan._step(g, PartKind.shape, 'Button: draw a rectangle');
        plan._step(g, PartKind.text, 'Write ${_q(label)} inside the button');
        link(go, 'the ${_q(label)} button', s);
      case InputNode(:final label):
        final g = plan._group('input', s, label: label);
        plan._step(g, PartKind.text, 'Input: write the label ${_q(label)}');
        plan._step(
          g,
          PartKind.shape,
          'Draw the input box (or a line) under the label',
        );
      case CheckNode(:final label):
        final g = plan._group('check', s, label: label);
        plan._step(g, PartKind.shape, 'Checkbox: draw a small square');
        plan._step(g, PartKind.text, 'Write ${_q(label)} to its right');
      case RadioNode(:final options):
        for (final o in options) {
          final g = plan._group('radio', s, label: o);
          plan._step(g, PartKind.shape, 'Radio option: draw a small circle');
          plan._step(g, PartKind.text, 'Write ${_q(o)} to its right');
        }
      case SwitchNode(:final label):
        final g = plan._group('switch', s, label: label);
        plan._step(g, PartKind.text, 'Switch: write the label ${_q(label)}');
        plan._step(
          g,
          PartKind.shape,
          'Draw a pill with a small circle inside, to the right of the label',
        );
      case ImageNode():
        final g = plan._group('img', s);
        plan._step(
          g,
          PartKind.shape,
          'Image: draw a rectangle with an X inside',
        );
      case IconNode(:final name, :final go):
        final menu = name == 'menu';
        final g = plan._group(menu ? 'menu' : 'icon', s);
        plan._step(
          g,
          PartKind.shape,
          menu
              ? 'Menu: draw three short lines'
              : 'Icon: draw a small doodle or circle',
        );
        link(go, menu ? 'the menu icon' : 'the icon', s);
      case AvatarNode(:final go):
        final g = plan._group('avatar', s);
        plan._step(
          g,
          PartKind.shape,
          'Avatar: draw a circle with a smaller circle inside',
        );
        link(go, 'the avatar', s);
      case DividerNode():
        final g = plan._group('divider', s);
        plan._step(g, PartKind.shape, 'Divider: draw a long horizontal line');
      case SpacerNode():
        break;
    }
  }

  for (var s = 0; s < spec.screens.length; s++) {
    final screen = spec.screens[s];
    final bar = screen.appbar;
    if (bar != null) {
      final g = plan._group('appbar', s, label: bar.title);
      plan._step(
        g,
        PartKind.shape,
        'Screen ${s + 1} app bar: draw a band (or a line) across the top',
      );
      plan._step(
        g,
        PartKind.text,
        'Write the title ${_q(bar.title)} in the band',
      );
      for (final icon in bar.icons) {
        node(icon, s);
      }
    }
    node(screen.body, s);
    final nav = screen.bottomnav;
    if (nav != null) {
      final g = plan._group('bottomnav', s);
      plan._step(
        g,
        PartKind.shape,
        'Bottom bar: draw a band (or a line) across the bottom',
      );
      for (final item in nav.items) {
        final ig = plan._group('icon', s);
        plan._step(ig, PartKind.shape, 'Draw an icon in the bottom bar');
        final tg = plan._group('text', s, label: item.label);
        plan._step(
          tg,
          PartKind.text,
          'Write ${_q(item.label)} under that icon',
        );
        link(item.go, 'the ${_q(item.label)} tab', s);
      }
    }
    final fab = screen.fab;
    if (fab != null) {
      final g = plan._group('fab', s);
      plan._step(
        g,
        PartKind.shape,
        'Floating button: draw a circle with a + near the bottom-right',
      );
      link(fab.go, 'the + button', s);
    }
  }

  for (final (what, target, from) in links) {
    final to = spec.screens.indexWhere((x) => x.id == target);
    if (to < 0 || to == from) continue;
    plan.groups.add(
      CollectGroup('arrow', 'arrow', from)
        ..arrowFrom = what
        ..arrowTo = to,
    );
    plan._step(
      plan.groups.length - 1,
      PartKind.arrow,
      'Draw an arrow from $what to screen ${to + 1}',
    );
  }
  return plan;
}

/// Builds the labelled record from the finished drawing. [stepStrokes] holds the stroke ids drawn in
/// each step (same order as plan.steps).
Map<String, Object?> buildRecord({
  required String id,
  required String participant,
  required String taskId,
  required AppSpec spec,
  required CollectPlan plan,
  required InkDocument doc,
  required List<List<int>> stepStrokes,
}) {
  final n = doc.strokes.length;
  final strokeCls = List<String>.filled(n, 'shape');
  final strokeGroup = List<int>.filled(n, -1);
  final groupStrokes = [for (final _ in plan.groups) <int>[]];
  final groupText = [for (final _ in plan.groups) <int>[]];
  final index = {for (var i = 0; i < n; i++) doc.strokes[i].id: i};
  for (var k = 0; k < plan.steps.length; k++) {
    final step = plan.steps[k];
    for (final sid in stepStrokes[k]) {
      final i = index[sid];
      if (i == null) continue;
      strokeGroup[i] = step.group;
      strokeCls[i] = switch (step.part) {
        PartKind.text => 'text',
        PartKind.arrow => 'arrow',
        PartKind.shape => 'shape',
      };
      groupStrokes[step.group].add(i);
      if (step.part == PartKind.text) groupText[step.group].add(i);
    }
  }
  List<double> boxOf(List<int> ids) =>
      ids.map((i) => doc.strokes[i].box).reduce((a, b) => a.union(b)).toJson();

  final elements = <Map<String, Object?>>[];
  final arrows = <Map<String, Object?>>[];
  for (var g = 0; g < plan.groups.length; g++) {
    final grp = plan.groups[g];
    final ids = groupStrokes[g]..sort();
    if (ids.isEmpty) continue;
    if (grp.kind == 'arrow') {
      // Tail where the pen started, head where it ended (people draw towards the target).
      final first = doc.strokes[ids.first].points.first;
      final shaft = ids
          .map((i) => doc.strokes[i])
          .reduce((a, b) => a.length >= b.length ? a : b);
      arrows.add({
        'id': arrows.length,
        'strokes': ids,
        'tail': [first.x, first.y],
        'head': [shaft.points.last.x, shaft.points.last.y],
      });
    } else {
      elements.add({
        'id': elements.length,
        'type': grp.type,
        'box': boxOf(ids),
        'frame': grp.frame,
        'strokes': ids,
        if (groupText[g].isNotEmpty) 'text_strokes': groupText[g]..sort(),
        'text': ?grp.label,
      });
    }
  }
  return {
    'id': id,
    'participant': participant,
    'task': taskId,
    'ink': doc.toJson(),
    'stroke_cls': strokeCls,
    'stroke_group': strokeGroup,
    'groups': [
      for (final g in plan.groups)
        {
          'kind': g.kind,
          'type': g.kind == 'arrow' ? null : g.type,
          'frame': g.frame,
        },
    ],
    'elements': {
      'v': 1,
      'frames': [for (final f in doc.frames) f.toJson()],
      'elements': elements,
      'arrows': arrows,
    },
    'spec': spec.toJson(),
  };
}
