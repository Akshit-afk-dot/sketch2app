/// Screen naming rule shared with ml/s2a/spec/naming.py (fixture: spec/fixtures/naming.json).
///
/// Title = app-bar title, else first heading, else "Screen k"; id = slug of the title, deduplicated.
/// Gold specs use the same rule, so screen ids are predictable from the sketch.
library;

const defaultNavLabels = ['Home', 'Search', 'Profile', 'Settings', 'More'];

String slug(String title) {
  var out = title
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  if (out.isNotEmpty && !RegExp('^[a-z]').hasMatch(out)) out = 's_$out';
  return out;
}

/// (id, title) per screen; a null title means the screen has no app bar title or heading.
List<({String id, String title})> screenNames(List<String?> titles) {
  final used = <String>{};
  final out = <({String id, String title})>[];
  for (var k = 0; k < titles.length; k++) {
    final title = titles[k] ?? 'Screen ${k + 1}';
    var base = slug(title);
    if (base.isEmpty) base = 'screen${k + 1}';
    if (base.length > 28) base = base.substring(0, 28);
    var id = base;
    for (var n = 2; used.contains(id); n++) {
      id = '${base}_$n';
    }
    used.add(id);
    out.add((
      id: id,
      title: title.length > 40 ? title.substring(0, 40) : title,
    ));
  }
  return out;
}
