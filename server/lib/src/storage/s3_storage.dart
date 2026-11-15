import 'dart:io';
import 'dart:typed_data';

import 'package:minio/minio.dart';

import '../config.dart';
import '../storage.dart';

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
