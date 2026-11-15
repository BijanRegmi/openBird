import 'dart:io';

import 'package:path/path.dart' as p;

import '../crypto.dart';
import '../storage.dart';

/// Files on local disk, served by the server's `/api/v1/files` route.
class FsStorage implements Storage {
  FsStorage(this.root, this._signer);

  final String root;
  final UrlSigner _signer;

  File fileFor(String key) {
    final path = p.normalize(p.join(root, key));
    if (!p.isWithin(p.normalize(root), path)) {
      throw ArgumentError.value(key, 'key', 'escapes the storage root');
    }
    return File(path);
  }

  @override
  Future<void> init() => Directory(root).create(recursive: true);

  @override
  Future<void> putFile(String key, File file) async {
    final dest = fileFor(key);
    await dest.parent.create(recursive: true);
    try {
      await file.rename(dest.path);
    } on FileSystemException {
      // Staging and storage on different filesystems.
      await file.copy(dest.path);
      await file.delete();
    }
  }

  @override
  Future<String> downloadUrl(
    String key, {
    required Uri origin,
    required Duration ttl,
  }) async {
    final expires = DateTime.now().add(ttl).millisecondsSinceEpoch ~/ 1000;
    final path = '/api/v1/files/$key';
    final sig = _signer.signature(path, expires);
    return origin
        .replace(
          path: path,
          queryParameters: {'expires': '$expires', 'sig': sig},
        )
        .toString();
  }

  @override
  Future<void> deletePrefix(String prefix) async {
    final dir = Directory(fileFor(prefix).path);
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}
