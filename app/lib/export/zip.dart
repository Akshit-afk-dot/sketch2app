/// Zip an exported project. Pure Dart (package:archive) so it is testable without a device.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Files go under a top-level folder named after the package, as `flutter create` would lay them out.
Uint8List zipProject(Map<String, String> files, {required String rootFolder}) {
  final archive = Archive();
  for (final MapEntry(key: path, value: content) in files.entries) {
    archive.addFile(
      ArchiveFile.bytes('$rootFolder/$path', utf8.encode(content)),
    );
  }
  return ZipEncoder().encodeBytes(archive);
}
