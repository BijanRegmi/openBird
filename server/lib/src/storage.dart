import 'dart:io';
import 'dart:typed_data';

import 'package:minio/minio.dart';
import 'package:path/path.dart' as p;

import 'config.dart';
import 'crypto.dart';

/// Where artifacts live once uploaded. Uploads are assembled in a local
/// staging file first (both CLI upload methods go through the server), then
/// handed over with [putFile].
abstract class Storage {
  factory Storage.fromConfig(StorageConfig config, UrlSigner signer) =>
      switch (config) {
        FsStorageConfig(:final directory) => FsStorage(directory, signer),
        S3StorageConfig() => S3Storage(config),
      };

  Future<void> init();

  Future<void> putFile(String key, File file);

  /// A URL that downloads [key] without credentials until [ttl] passes.
  /// [origin] is the server's origin as the caller sees it.
  Future<String> downloadUrl(
    String key, {
    required Uri origin,
    required Duration ttl,
  });

  Future<void> deletePrefix(String prefix);
}

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

/// Any S3-compatible store. Downloads are presigned GETs straight from it,
/// which support the Range requests the updater resumes with.
class S3Storage implements Storage {
  S3Storage(this.config)
    : _client = Minio(
        endPoint: config.endpoint,
        port: config.port,
        useSSL: config.useSsl,
        accessKey: config.accessKey,
        secretKey: config.secretKey,
        region: config.region,
        pathStyle: true,
      );

  final S3StorageConfig config;
  final Minio _client;

  @override
  Future<void> init() async {
    if (!await _client.bucketExists(config.bucket)) {
      await _client.makeBucket(config.bucket, config.region);
    }
  }

  @override
  Future<void> putFile(String key, File file) async {
    await _client.putObject(
      config.bucket,
      key,
      file.openRead().map(Uint8List.fromList),
      size: await file.length(),
    );
    await file.delete();
  }

  @override
  Future<String> downloadUrl(
    String key, {
    required Uri origin,
    required Duration ttl,
  }) => _client.presignedGetObject(config.bucket, key, expires: ttl.inSeconds);

  @override
  Future<void> deletePrefix(String prefix) async {
    final keys = <String>[];
    await for (final page in _client.listObjects(
      config.bucket,
      prefix: prefix,
      recursive: true,
    )) {
      keys.addAll(page.objects.map((o) => o.key!));
    }
    if (keys.isNotEmpty) await _client.removeObjects(config.bucket, keys);
  }
}
