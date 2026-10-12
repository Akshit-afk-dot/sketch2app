/// Closed vocabulary of the UI spec. Mirrors ml/s2a/spec/vocab.py; the shared fixtures in spec/fixtures
/// fail if the two drift apart.
library;

const int specVersion = 1;

/// Canonical key order per object kind. A fixed order makes serialization unique.
const Map<String, List<String>> keyOrder = {
  'spec': ['v', 'screens'],
  'screen': ['id', 'title', 'appbar', 'body', 'bottomnav', 'fab'],
  'appbar': ['t', 'title', 'icons'],
  'bottomnav': ['t', 'items'],
  'navitem': ['icon', 'label', 'go'],
  'fab': ['t', 'icon', 'go'],
  'col': ['t', 'c'],
  'row': ['t', 'c'],
  'card': ['t', 'go', 'c'],
  'list': ['t', 'n', 'item'],
  'grid': ['t', 'cols', 'n', 'item'],
  'text': ['t', 'v', 's', 'go'],
  'para': ['t', 'lines'],
  'btn': ['t', 'label', 'variant', 'go'],
  'input': ['t', 'label', 'secure', 'multiline'],
  'check': ['t', 'label'],
  'radio': ['t', 'options'],
  'switch': ['t', 'label'],
  'img': ['t', 'h'],
  'icon': ['t', 'name', 'go'],
  'avatar': ['t', 'go'],
  'divider': ['t'],
  'spacer': ['t'],
};

const Set<String> bodyTypes = {
  'col', 'row', 'card', 'list', 'grid', 'text', 'para', 'btn', 'input', //
  'check', 'radio', 'switch', 'img', 'icon', 'avatar', 'divider', 'spacer',
};

const Set<String> repeatTypes = {'list', 'grid'};

const List<String> iconNames = [
  'circle',
  'menu',
  'search',
  'home',
  'person',
  'settings',
  'add',
  'back',
  'forward',
  'close', //
  'more',
  'favorite',
  'share',
  'bell',
  'chat',
  'camera',
  'cart',
  'star',
  'edit',
  'delete',
  'info',
  'mail',
  'phone',
  'location',
  'calendar',
  'check',
  'play',
  'image',
  'list',
  'filter',
  'lock',
  'logout',
  'send',
  'mic',
  'download',
  'refresh',
  'map',
  'music',
  'help',
];

const int maxDepth = 10;
