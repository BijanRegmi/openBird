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
      'azure' => AzureBlobStorageConfig.fromEnvironment(env),
      _ => throw StateError(
        'STORAGE must be fs, s3 or azure, not $storageKind',
      ),
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

/// Azure Blob Storage, authenticated with the storage account's shared key.
/// [endpoint] is the blob service URL (`https://<account>.blob.core.windows.net`
/// by default, or Azurite's `http://127.0.0.1:10000/devstoreaccount1`).
class AzureBlobStorageConfig extends StorageConfig {
  AzureBlobStorageConfig({
    required this.accountName,
    required this.accountKey,
    required this.container,
    Uri? endpoint,
    this.publicEndpoint,
  }) : endpoint =
           endpoint ?? Uri.parse('https://$accountName.blob.core.windows.net');

  /// From `AZURE_STORAGE_CONNECTION_STRING`, or `AZURE_STORAGE_ACCOUNT` and
  /// `AZURE_STORAGE_KEY` (plus an optional `AZURE_STORAGE_ENDPOINT`).
  factory AzureBlobStorageConfig.fromEnvironment(Map<String, String> env) {
    String? get(String name) {
      final value = env[name];
      return value == null || value.isEmpty ? null : value;
    }

    final container = get('AZURE_STORAGE_CONTAINER') ?? 'openbird';
    final publicEndpoint = get('AZURE_STORAGE_PUBLIC_ENDPOINT');
    final connectionString = get('AZURE_STORAGE_CONNECTION_STRING');
    if (connectionString != null) {
      return AzureBlobStorageConfig.fromConnectionString(
        connectionString,
        container: container,
        publicEndpoint: publicEndpoint == null
            ? null
            : Uri.parse(publicEndpoint),
      );
    }
    final account = get('AZURE_STORAGE_ACCOUNT');
    final key = get('AZURE_STORAGE_KEY');
    if (account == null || key == null) {
      throw StateError(
        'STORAGE=azure needs AZURE_STORAGE_CONNECTION_STRING, or '
        'AZURE_STORAGE_ACCOUNT and AZURE_STORAGE_KEY',
      );
    }
    final endpoint = get('AZURE_STORAGE_ENDPOINT');
    return AzureBlobStorageConfig(
      accountName: account,
      accountKey: key,
      container: container,
      endpoint: endpoint == null ? null : Uri.parse(endpoint),
      publicEndpoint: publicEndpoint == null ? null : Uri.parse(publicEndpoint),
    );
  }

  /// Parses a storage account connection string as the Azure portal shows
  /// it, including `UseDevelopmentStorage=true` for Azurite.
  factory AzureBlobStorageConfig.fromConnectionString(
    String connectionString, {
    required String container,
    Uri? publicEndpoint,
  }) {
    final parts = <String, String>{};
    for (final part in connectionString.split(';')) {
      final eq = part.indexOf('=');
      if (eq <= 0) continue;
      parts[part.substring(0, eq).trim().toLowerCase()] = part
          .substring(eq + 1)
          .trim();
    }
    if (parts['usedevelopmentstorage'] == 'true') {
      return AzureBlobStorageConfig(
        accountName: azuriteAccount,
        accountKey: azuriteKey,
        container: container,
        endpoint: Uri.parse(
          parts['developmentstorageproxyuri'] ??
              'http://127.0.0.1:10000/$azuriteAccount',
        ),
        publicEndpoint: publicEndpoint,
      );
    }
    final account = parts['accountname'];
    final key = parts['accountkey'];
    if (account == null || key == null) {
      throw StateError(
        'AZURE_STORAGE_CONNECTION_STRING needs AccountName and AccountKey '
        '(SAS-only connection strings are not supported)',
      );
    }
    final blobEndpoint = parts['blobendpoint'];
    final protocol = parts['defaultendpointsprotocol'] ?? 'https';
    final suffix = parts['endpointsuffix'] ?? 'core.windows.net';
    return AzureBlobStorageConfig(
      accountName: account,
      accountKey: key,
      container: container,
      endpoint: Uri.parse(blobEndpoint ?? '$protocol://$account.blob.$suffix'),
      publicEndpoint: publicEndpoint,
    );
  }

  /// Azurite's well-known development account.
  static const azuriteAccount = 'devstoreaccount1';
  static const azuriteKey =
      'Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==';

  final String accountName;

  /// The account key, base64 as the portal shows it.
  final String accountKey;
  final String container;
  final Uri endpoint;

  /// The blob service URL clients download from, when it differs from
  /// [endpoint] (e.g. the server reaches Azurite as `azurite:10000` inside
  /// docker compose, devices as `localhost:10000`).
  final Uri? publicEndpoint;
}
