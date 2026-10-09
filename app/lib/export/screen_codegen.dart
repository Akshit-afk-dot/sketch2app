/// Spec -> Dart widget code for one screen. Mirrors lib/render/spec_renderer.dart node for node; the
/// mapping table in DESIGN.md is the shared contract.
library;

import '../spec/spec.dart';
import 'code.dart';

/// Helper widgets that live in the exported lib/sketch_widgets.dart.
const sketchWidgetNames = {
  'goTo',
  'PlaceholderImage',
  'Paragraph',
  'GridOf',
  'CheckField',
  'SwitchField',
  'RadioField',
};

String routeName(AppSpec spec, String id) =>
    id == spec.screens.first.id ? '/' : '/$id';

String screenClassName(String id) =>
    '${id.split('_').where((p) => p.isNotEmpty).map((p) => p[0].toUpperCase() + p.substring(1)).join()}Screen';

String screenFileName(String id) => '${id}_screen.dart';

class ScreenCodegen {
  ScreenCodegen(this.spec);

  final AppSpec spec;

  /// Helper names referenced by the last generated screen, to decide whether to import them.
  final usedHelpers = <String>{};

  static const _context = Raw('context', isConst: false);

  Code _icon(String name) =>
      Call('Icon', args: [Raw('Icons.${materialIconIds[name]}')]);

  Code _text(String v, {Code? style}) => Call(
    'Text',
    args: [str(v)],
    named: [if (style != null) ('style', style)],
  );

  Code _themeText(String style) =>
      Raw('Theme.of(context).textTheme.$style', isConst: false);

  /// Tap handler: navigate when linked, otherwise an enabled no-op (matches the preview).
  Code _action(String? go) {
    if (go == null) return const Raw('() {}', isConst: false);
    usedHelpers.add('goTo');
    return Closure(
      '()',
      Call(
        'goTo',
        constCapable: false,
        args: [_context, str(routeName(spec, go))],
      ),
    );
  }

  Code _column(List<SpecNode> c, int spacing) => Call(
    'Column',
    named: [
      ('crossAxisAlignment', const Raw('CrossAxisAlignment.stretch')),
      ('spacing', Raw('$spacing')),
      ('children', ListCode([for (final n in c) node(n)])),
    ],
  );

  Code _helper(String name, List<(String, Code)> named) {
    usedHelpers.add(name);
    return Call(name, named: named);
  }

  Code node(SpecNode n) => switch (n) {
    ColNode(:final c) => _column(c, 12),
    RowNode(:final c) => Call(
      'Row',
      named: [
        ('spacing', const Raw('8')),
        (
          'children',
          ListCode([
            for (final x in c)
              x is IconNode || x is AvatarNode
                  ? node(x)
                  : Call('Expanded', named: [('child', node(x))]),
          ]),
        ),
      ],
    ),
    CardNode(:final c, :final go) => _card(c, go),
    ListNode(:final n, :final item) => Call(
      'Column',
      named: [
        ('crossAxisAlignment', const Raw('CrossAxisAlignment.stretch')),
        ('spacing', const Raw('8')),
        (
          'children',
          ListCode([ForElement('for (var i = 0; i < $n; i++)', node(item))]),
        ),
      ],
    ),
    GridNode(:final cols, :final n, :final item) => _helper('GridOf', [
      ('columns', Raw('$cols')),
      ('count', Raw('$n')),
      ('itemBuilder', Closure('(context, index)', node(item))),
    ]),
    TextNode() => _textNode(n),
    ParaNode(:final lines) => _helper('Paragraph', [('lines', Raw('$lines'))]),
    ButtonNode(:final label, :final variant, :final go) => Call(
      switch (variant) {
        ButtonVariant.primary => 'FilledButton',
        ButtonVariant.secondary => 'OutlinedButton',
        ButtonVariant.text => 'TextButton',
      },
      named: [('onPressed', _action(go)), ('child', _text(label))],
    ),
    InputNode(:final label, :final secure, :final multiline) => Call(
      'TextField',
      named: [
        if (secure) ('obscureText', const Raw('true')),
        if (multiline) ('minLines', const Raw('3')),
        if (multiline) ('maxLines', const Raw('5')),
        (
          'decoration',
          Call(
            'InputDecoration',
            named: [
              ('labelText', str(label)),
              ('border', Call('OutlineInputBorder')),
            ],
          ),
        ),
      ],
    ),
    CheckNode(:final label) => _helper('CheckField', [('label', str(label))]),
    RadioNode(:final options) => _helper('RadioField', [
      ('options', ListCode([for (final o in options) str(o)])),
    ]),
    SwitchNode(:final label) => _helper('SwitchField', [('label', str(label))]),
    ImageNode(:final h) => _helper('PlaceholderImage', [
      ('heightFactor', Raw('${h / 100}')),
    ]),
    IconNode(:final name, :final go) => Call(
      'IconButton',
      named: [('onPressed', _action(go)), ('icon', _icon(name))],
    ),
    AvatarNode(:final go) => _avatar(go),
    DividerNode() => Call('Divider'),
    SpacerNode() => Call('SizedBox', named: [('height', const Raw('24'))]),
  };

  Code _card(List<SpecNode> c, String? go) {
    final content = Call(
      'Padding',
      named: [
        ('padding', Call('EdgeInsets.all', args: [const Raw('12')])),
        ('child', _column(c, 8)),
      ],
    );
    if (go == null) return Call('Card', named: [('child', content)]);
    return Call(
      'Card',
      named: [
        ('clipBehavior', const Raw('Clip.antiAlias')),
        (
          'child',
          Call('InkWell', named: [('onTap', _action(go)), ('child', content)]),
        ),
      ],
    );
  }

  Code _textNode(TextNode n) {
    if (n.s == TextKind.link) {
      return Call(
        'TextButton',
        named: [('onPressed', _action(n.go)), ('child', _text(n.v))],
      );
    }
    final text = switch (n.s) {
      TextKind.h1 => _text(n.v, style: _themeText('headlineSmall')),
      TextKind.h2 => _text(n.v, style: _themeText('titleLarge')),
      TextKind.caption => _text(n.v, style: _themeText('bodySmall')),
      TextKind.body || TextKind.link => _text(n.v),
    };
    if (n.go == null) return text;
    return Call('InkWell', named: [('onTap', _action(n.go)), ('child', text)]);
  }

  Code _avatar(String? go) {
    final avatar = Call(
      'CircleAvatar',
      named: [
        ('child', Call('Icon', args: [const Raw('Icons.person')])),
      ],
    );
    if (go == null) return avatar;
    return Call(
      'InkWell',
      named: [
        ('onTap', _action(go)),
        ('customBorder', Call('CircleBorder')),
        ('child', avatar),
      ],
    );
  }

  /// The whole `Scaffold(...)` expression returned by the screen's build method.
  Code scaffold(ScreenSpec screen) {
    final appbar = screen.appbar;
    final nav = screen.bottomnav;
    final fab = screen.fab;
    return Call(
      'Scaffold',
      named: [
        if (appbar != null)
          (
            'appBar',
            Call(
              'AppBar',
              constCapable: false, // AppBar has no const constructor
              named: [
                ('title', _text(appbar.title)),
                if (appbar.icons.isNotEmpty)
                  (
                    'actions',
                    ListCode([for (final i in appbar.icons) node(i)]),
                  ),
              ],
            ),
          ),
        (
          'body',
          Call(
            'SafeArea',
            named: [
              (
                'child',
                Call(
                  'SingleChildScrollView',
                  named: [
                    (
                      'padding',
                      Call('EdgeInsets.all', args: [const Raw('16')]),
                    ),
                    ('child', node(screen.body)),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (nav != null) ('bottomNavigationBar', _navBar(screen, nav)),
        if (fab != null)
          (
            'floatingActionButton',
            Call(
              'FloatingActionButton',
              named: [
                ('onPressed', _action(fab.go)),
                ('child', _icon(fab.icon)),
              ],
            ),
          ),
      ],
    );
  }

  Code _navBar(ScreenSpec screen, BottomNavSpec nav) {
    usedHelpers.add('goTo');
    final selected = nav.items.indexWhere((i) => i.go == screen.id);
    final routes = [
      for (final i in nav.items)
        i.go == null ? 'null' : str(routeName(spec, i.go!)).text,
    ];
    return Call(
      'NavigationBar',
      named: [
        ('selectedIndex', Raw('${selected < 0 ? 0 : selected}')),
        (
          'onDestinationSelected',
          Closure(
            '(index)',
            Call(
              'goTo',
              constCapable: false,
              args: [
                _context,
                Raw(
                  'const <String?>[${routes.join(', ')}][index]',
                  isConst: false,
                ),
              ],
              named: [('replace', const Raw('true'))],
            ),
          ),
        ),
        (
          'destinations',
          ListCode([
            for (final i in nav.items)
              Call(
                'NavigationDestination',
                named: [('icon', _icon(i.icon)), ('label', str(i.label))],
              ),
          ]),
        ),
      ],
    );
  }
}
