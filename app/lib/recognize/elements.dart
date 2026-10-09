/// Element list (spec/schema/elements.v1.schema.json): recognizer + handwriting output, layout input.
library;

import '../ink/ink_model.dart';

enum ElementType {
  btn('btn'),
  input('input'),
  text('text'),
  heading('heading'),
  para('para'),
  img('img'),
  icon('icon'),
  menu('menu'),
  avatar('avatar'),
  check('check'),
  radio('radio'),
  toggle('switch'),
  divider('divider'),
  card('card'),
  appbar('appbar'),
  bottomnav('bottomnav'),
  fab('fab'),
  listmark('listmark');

  const ElementType(this.json);

  /// Name used in JSON and by the Python side (`switch` is a Dart keyword, hence [toggle]).
  final String json;

  static ElementType fromJson(String s) =>
      values.firstWhere((e) => e.json == s);

  /// Element types whose handwritten text is read by the handwriting recognizer. Icons are read too,
  /// because a short `xN` list mark is easily mistaken for a doodle.
  bool get hasText => const {
    icon,
    btn,
    input,
    text,
    heading,
    check,
    radio,
    toggle,
    appbar,
    listmark,
  }.contains(this);

  /// Elements that geometrically contain other elements.
  bool get isContainer => this == card || this == appbar || this == bottomnav;
}

class SketchElement {
  SketchElement({
    required this.id,
    required this.type,
    required this.box,
    this.frame,
    this.strokes = const [],
    this.textStrokes = const [],
    this.text,
    this.score = 1,
  });

  factory SketchElement.fromJson(Map<String, Object?> j) => SketchElement(
    id: j['id']! as int,
    type: ElementType.fromJson(j['type']! as String),
    box: Box.fromJson(j['box']! as List<Object?>),
    frame: j['frame'] as int?,
    strokes: [...((j['strokes'] as List<Object?>?) ?? const []).cast<int>()],
    textStrokes: [
      ...((j['text_strokes'] as List<Object?>?) ?? const []).cast<int>(),
    ],
    text: j['text'] as String?,
    score: (j['score'] as num?)?.toDouble() ?? 1,
  );

  final int id;
  ElementType type;
  Box box;
  int? frame;
  List<int> strokes;
  List<int> textStrokes;

  /// Filled in by the handwriting stage.
  String? text;
  double score;

  Map<String, Object?> toJson() => {
    'id': id,
    'type': type.json,
    'box': box.toJson(),
    'frame': ?frame,
    'strokes': strokes,
    if (textStrokes.isNotEmpty) 'text_strokes': textStrokes,
    'text': ?text,
    'score': score,
  };

  @override
  String toString() => '${type.json}#$id$box${text == null ? '' : ' "$text"'}';
}

class SketchArrow {
  const SketchArrow({
    required this.id,
    required this.tail,
    required this.head,
    this.strokes = const [],
  });

  factory SketchArrow.fromJson(Map<String, Object?> j) {
    (double, double) pt(Object? p) {
      final xy = p! as List<Object?>;
      return ((xy[0]! as num).toDouble(), (xy[1]! as num).toDouble());
    }

    return SketchArrow(
      id: j['id']! as int,
      tail: pt(j['tail']),
      head: pt(j['head']),
      strokes: [...((j['strokes'] as List<Object?>?) ?? const []).cast<int>()],
    );
  }

  final int id;
  final (double, double) tail;
  final (double, double) head;
  final List<int> strokes;

  Map<String, Object?> toJson() => {
    'id': id,
    'strokes': strokes,
    'tail': [tail.$1, tail.$2],
    'head': [head.$1, head.$2],
  };
}

class ElementList {
  ElementList({
    required this.frames,
    required this.elements,
    required this.arrows,
  });

  factory ElementList.fromJson(Map<String, Object?> j) => ElementList(
    frames: [
      for (final f in j['frames']! as List<Object?>)
        InkFrame.fromJson(f! as Map<String, Object?>),
    ],
    elements: [
      for (final e in j['elements']! as List<Object?>)
        SketchElement.fromJson(e! as Map<String, Object?>),
    ],
    arrows: [
      for (final a in j['arrows']! as List<Object?>)
        SketchArrow.fromJson(a! as Map<String, Object?>),
    ],
  );

  final List<InkFrame> frames;
  final List<SketchElement> elements;
  final List<SketchArrow> arrows;

  Map<String, Object?> toJson() => {
    'v': 1,
    'frames': [for (final f in frames) f.toJson()],
    'elements': [for (final e in elements) e.toJson()],
    'arrows': [for (final a in arrows) a.toJson()],
  };
}
