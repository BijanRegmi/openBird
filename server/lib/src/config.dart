import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Server settings, read from the environment (see `.env.example`).
class Config {
  Config({
    required this.port,
    required this.databaseUrl,
    required this.masterKey,
    required this.storage,
    required this.stagingDir,
    this.publicUrl,
    this.trustProxy = false,
    this.downloadUrlTtl = const Duration(hours: 24),
    this.uploadSessionTtl = const Duration(hours: 24),
    this.migrationsDir = 'migrations',
    this.dashboardDir,
    this.allowSignup = false,
    this.secureCookies = false,
  });

  factory Config.fromEnvironment([Map<String, String>? environment]) {
    final env = environment ?? Platform.environment;
    String require(String name) {
      final value = env[name];
      if (value == null || value.isEmpty) {
        throw StateError('$name must be set');
      }
      return value;
    }

    final masterKey = base64.decode(require('MASTER_KEY'));
    if (masterKey.length != 32) {
      throw StateError('MASTER_KEY must be 32 bytes, base64 encoded');
    }
    final storageKind = env['STORAGE'] ?? 'fs';
    final StorageConfig storage = switch (storageKind) {
      'fs' => FsStorageConfig(env['STORAGE_DIR'] ?? 'data/storage'),
      's3' => S3StorageConfig(
        endpoint: require('S3_ENDPOINT'),
        port: int.tryParse(env['S3_PORT'] ?? ''),
        useSsl: (env['S3_USE_SSL'] ?? 'true') == 'true',
        accessKey: require('S3_ACCESS_KEY'),
        secretKey: require('S3_SECRET_KEY'),
        bucket: require('S3_BUCKET'),
        region: env['S3_REGION'],
      ),
      _ => throw StateError('STORAGE must be fs or s3, not $storageKind'),
    };
    final publicUrl = env['PUBLIC_URL'];
    return Config(
      port: int.parse(env['PORT'] ?? '8080'),
      databaseUrl: require('DATABASE_URL'),
      masterKey: Uint8List.fromList(masterKey),
      storage: storage,
      stagingDir: env['STAGING_DIR'] ?? 'data/staging',
      publicUrl: publicUrl == null || publicUrl.isEmpty
          ? null
          : Uri.parse(publicUrl.replaceFirst(RegExp(r'/+$'), '')),
      trustProxy: env['TRUST_PROXY'] == 'true',
      migrationsDir: env['MIGRATIONS_DIR'] ?? 'migrations',
      dashboardDir: env['DASHBOARD_DIR'],
      allowSignup: env['ALLOW_SIGNUP'] == 'true',
      secureCookies:
          env['SECURE_COOKIES'] == 'true' ||
          (publicUrl?.startsWith('https://') ?? false),
    );
  }

  final int port;
  final String databaseUrl;

  /// Encrypts managed signing keys and keys the download URL signatures.
  final Uint8List masterKey;
  final StorageConfig storage;

  /// Where uploads are assembled before they move into [storage].
  final String stagingDir;

  /// The origin the server's own URLs (uploads, downloads) are built on.
  /// When null, each request's own origin is used, so the CLI on the host
  /// and an emulator reaching the host under another address both get URLs
  /// they can resolve.
  final Uri? publicUrl;

  /// Whether to honour X-Forwarded-Proto/Host from a reverse proxy.
  final bool trustProxy;
  final Duration downloadUrlTtl;
  final Duration uploadSessionTtl;
  final String migrationsDir;

  /// The built console (dashboard/dist), served at `/` when set.
  final String? dashboardDir;

  /// Whether anyone may create an account in the console. The first account
  /// can always be created; later ones otherwise need an invitation.
  final bool allowSignup;

  /// Marks the session cookie Secure (on by default behind an https PUBLIC_URL).
  final bool secureCookies;
}

sealed class StorageConfig {}

class FsStorageConfig extends StorageConfig {
  FsStorageConfig(this.directory);
  final String directory;
}

class S3StorageConfig extends StorageConfig {
  S3StorageConfig({
    required this.endpoint,
    required this.accessKey,
    required this.secretKey,
    required this.bucket,
    this.port,
    this.useSsl = true,
    this.region,
  });

  final String endpoint;
  final int? port;
  final bool useSsl;
  final String accessKey;
  final String secretKey;
  final String bucket;
  final String? region;
}
