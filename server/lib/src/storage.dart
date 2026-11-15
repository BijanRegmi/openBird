import 'dart:io';

import 'config.dart';
import 'crypto.dart';
import 'storage/azure_blob_storage.dart';
import 'storage/fs_storage.dart';
import 'storage/s3_storage.dart';

export 'storage/azure_blob_storage.dart';
export 'storage/fs_storage.dart';
export 'storage/s3_storage.dart';

/// Where artifacts live once uploaded. Uploads are assembled in a local
/// staging file first (both CLI upload methods go through the server), then
/// handed over with [putFile].
///
/// Each backend is an adapter in `storage/`; [Storage.fromConfig] picks one
/// from the `STORAGE` setting. A new backend needs a [StorageConfig] subclass,
/// an adapter implementing this interface, and a case below.
abstract class Storage {
  factory Storage.fromConfig(StorageConfig config, UrlSigner signer) =>
      switch (config) {
        FsStorageConfig(:final directory) => FsStorage(directory, signer),
        S3StorageConfig() => S3Storage(config),
        AzureBlobStorageConfig() => AzureBlobStorage(config),
      };

  /// Prepares the backend (creates the directory, bucket or container).
  Future<void> init();

  /// Moves [file] to [key]. The file is consumed.
  Future<void> putFile(String key, File file);

  /// A URL that downloads [key] without credentials until [ttl] passes. It
  /// must honour `Range` and serve the bytes without content encoding (the
  /// updater resumes downloads and checks the body against Content-Length).
  /// [origin] is the server's origin as the caller sees it.
  Future<String> downloadUrl(
    String key, {
    required Uri origin,
    required Duration ttl,
  });

  /// Deletes every object whose key starts with [prefix].
  Future<void> deletePrefix(String prefix);
}

/// A storage backend refused or failed an operation.
class StorageException implements Exception {
  StorageException(this.message, [this.details]);

  final String message;

  /// The backend's response body, when it sent one.
  final String? details;

  @override
  String toString() =>
      details == null || details!.isEmpty ? message : '$message\n$details';
}
