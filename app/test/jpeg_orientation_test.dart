import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sketch2app/photo/jpeg_orientation.dart';

/// SOI, an APP1 Exif segment carrying only the orientation tag, then a SOF0 frame header.
Uint8List _jpeg({
  required int w,
  required int h,
  int? orientation,
  bool little = true,
}) {
  int hi(int v) => (v >> 8) & 0xFF;
  int lo(int v) => v & 0xFF;
  List<int> u16(int v) => little ? [lo(v), hi(v)] : [hi(v), lo(v)];
  List<int> u32(int v) => little ? [lo(v), hi(v), 0, 0] : [0, 0, hi(v), lo(v)];
  final exif = <int>[
    ...'Exif'.codeUnits, 0, 0, //
    ...(little ? [0x49, 0x49] : [0x4D, 0x4D]), ...u16(42), ...u32(8),
    ...u16(1), // one IFD0 entry
    ...u16(0x0112), ...u16(3), ...u32(1), ...u16(orientation ?? 1), 0, 0,
    ...u32(0),
  ];
  return Uint8List.fromList([
    0xFF, 0xD8, //
    if (orientation != null) ...[
      0xFF,
      0xE1,
      hi(exif.length + 2),
      lo(exif.length + 2),
      ...exif,
    ],
    0xFF, 0xC0, 0, 17, 8, hi(h), lo(h), hi(w), lo(w), 3, //
    1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1,
    0xFF, 0xD9,
  ]);
}

void main() {
  test('reads stored size and orientation (little- and big-endian EXIF)', () {
    for (final little in [true, false]) {
      final info = readJpegInfo(
        _jpeg(w: 4032, h: 3024, orientation: 6, little: little),
      )!;
      expect((info.width, info.height, info.orientation), (4032, 3024, 6));
      expect(info.quarterTurn, isTrue);
    }
  });

  test('no EXIF means upright; non-JPEG is null', () {
    final info = readJpegInfo(_jpeg(w: 640, h: 480))!;
    expect(
      (info.width, info.height, info.orientation, info.quarterTurn),
      (640, 480, 1, false),
    );
    expect(readJpegInfo(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47])), isNull);
  });
}
