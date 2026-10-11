/// JPEG header facts needed to orient a photo: the stored (raw) size and the EXIF orientation tag.
///
/// Why: phone cameras store portrait photos sideways plus an orientation tag, and image_picker keeps the
/// tag without rotating pixels. If the platform decoder ever ignores the tag, the sketch reaches the
/// vectorizer rotated by 90 degrees and recognition fails completely; comparing the decoded size with the
/// raw size tells whether the decoder applied it. Pure Dart, no dependencies.
library;

import 'dart:typed_data';

class JpegInfo {
  const JpegInfo(this.width, this.height, this.orientation);

  /// Pixel size as stored, before any EXIF rotation.
  final int width;
  final int height;

  /// EXIF orientation 1-8 (1 = upright, 6 = rotate 90 clockwise, 8 = 90 anticlockwise, 3 = 180).
  final int orientation;

  /// Orientations 5-8 swap width and height.
  bool get quarterTurn => orientation >= 5 && orientation <= 8;
}

/// Null when [bytes] is not a JPEG or has no frame header.
JpegInfo? readJpegInfo(Uint8List bytes) {
  if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) return null;
  var orientation = 1;
  var i = 2;
  while (i + 4 <= bytes.length) {
    if (bytes[i] != 0xFF) return null;
    final marker = bytes[i + 1];
    if (marker == 0xD8 ||
        (marker >= 0xD0 && marker <= 0xD7) ||
        marker == 0x01) {
      i += 2;
      continue;
    }
    final len = (bytes[i + 2] << 8) | bytes[i + 3];
    final body = i + 4;
    if (marker == 0xE1 && body + 6 <= bytes.length) {
      orientation =
          _exifOrientation(bytes, body, body + len - 2) ?? orientation;
    }
    final isSof =
        marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC;
    if (isSof && body + 5 <= bytes.length) {
      final h = (bytes[body + 1] << 8) | bytes[body + 2];
      final w = (bytes[body + 3] << 8) | bytes[body + 4];
      return JpegInfo(w, h, orientation);
    }
    // Scan data before a frame header: malformed.
    if (marker == 0xDA) return null;
    i += 2 + len;
  }
  return null;
}

int? _exifOrientation(Uint8List b, int start, int end) {
  // "Exif\0\0" then a TIFF header: byte order, 42, offset of IFD0.
  if (end > b.length || end - start < 14) return null;
  if (String.fromCharCodes(b, start, start + 4) != 'Exif') return null;
  final tiff = start + 6;
  final little = b[tiff] == 0x49; // "II" little-endian, "MM" big-endian
  int u16(int o) => little ? b[o] | (b[o + 1] << 8) : (b[o] << 8) | b[o + 1];
  int u32(int o) => little
      ? b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)
      : (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
  final ifd = tiff + u32(tiff + 4);
  if (ifd + 2 > end) return null;
  final count = u16(ifd);
  for (var k = 0; k < count; k++) {
    final entry = ifd + 2 + 12 * k;
    if (entry + 12 > end) return null;
    if (u16(entry) == 0x0112) {
      final v = u16(entry + 8);
      return v >= 1 && v <= 8 ? v : null;
    }
  }
  return null;
}
