import 'dart:io';

import 'package:openbird_server/openbird_server.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

/// Config parsing always runs; the storage round trip runs against the
/// docker-compose Azurite service (or AZURE_TEST_ENDPOINT) and is skipped
/// when none is reachable.
void main() {
  group('config', () {
    test('account connection string', () {
      final c = AzureBlobStorageConfig.fromConnectionString(
        'DefaultEndpointsProtocol=https;AccountName=acme;'
        'AccountKey=a2V5;EndpointSuffix=core.windows.net',
        container: 'patches',
      );
      expect(c.accountName, 'acme');
      expect(c.accountKey, 'a2V5');
      expect(c.endpoint.toString(), 'https://acme.blob.core.windows.net');
    });

    test('explicit BlobEndpoint and development storage', () {
      expect(
        AzureBlobStorageConfig.fromConnectionString(
          'AccountName=acme;AccountKey=a2V5;BlobEndpoint=https://cdn.example.com',
          container: 'c',
        ).endpoint.host,
        'cdn.example.com',
      );
      final dev = AzureBlobStorageConfig.fromConnectionString(
        'UseDevelopmentStorage=true',
        container: 'c',
      );
      expect(dev.accountName, 'devstoreaccount1');
      expect(
        dev.endpoint.toString(),
        'http://127.0.0.1:10000/devstoreaccount1',
      );
    });

    test('STORAGE=azure from the environment', () {
      final config = Config.fromEnvironment({
        'DATABASE_URL': 'postgres://x',
        'MASTER_KEY': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
        'STORAGE': 'azure',
        'AZURE_STORAGE_ACCOUNT': 'acme',
        'AZURE_STORAGE_KEY': 'a2V5',
        'AZURE_STORAGE_CONTAINER': 'artifacts',
      });
      final storage = config.storage as AzureBlobStorageConfig;
      expect(storage.container, 'artifacts');
      expect(storage.endpoint.host, 'acme.blob.core.windows.net');
      expect(
        () => Config.fromEnvironment({
          'DATABASE_URL': 'postgres://x',
          'MASTER_KEY': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
          'STORAGE': 'azure',
        }),
        throwsStateError,
      );
    });
  });

  final endpoint = Uri.parse(
    Platform.environment['AZURE_TEST_ENDPOINT'] ??
        'http://127.0.0.1:10000/devstoreaccount1',
  );
  Future<bool> reachable() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
    try {
      final response = await (await client.getUrl(endpoint)).close();
      await response.drain<void>();
      return true;
    } on Object {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  test('put, SAS download with Range, delete prefix', () async {
    if (!await reachable()) {
      markTestSkipped('no Azurite at $endpoint');
      return;
    }
    final storage = AzureBlobStorage(
      AzureBlobStorageConfig(
        accountName: AzureBlobStorageConfig.azuriteAccount,
        accountKey: AzureBlobStorageConfig.azuriteKey,
        container: 'openbird-test',
        endpoint: endpoint,
      ),
    );
    await storage.init();
    await storage.init(); // Idempotent.
    final dir = await Directory.systemTemp.createTemp('azure');
    addTearDown(() => dir.delete(recursive: true));
    final bytes = List<int>.generate(5000, (i) => i & 0xff);
    Future<void> put(String key) async {
      final file = File('${dir.path}/f')..writeAsBytesSync(bytes);
      await storage.putFile(key, file);
      expect(file.existsSync(), isFalse);
    }

    await put('apps/x/patches/1/aarch64');
    await put('apps/x/patches/1/arm');
    await put('apps/y/patches/1/arm');

    Future<Uri> url(String key) async => Uri.parse(
      await storage.downloadUrl(
        key,
        origin: Uri.parse('http://unused'),
        ttl: const Duration(minutes: 5),
      ),
    );
    final download = await url('apps/x/patches/1/aarch64');
    final full = await http.get(download);
    expect(full.statusCode, 200);
    expect(full.bodyBytes, bytes);
    expect(full.headers['content-encoding'], isNull);
    final rest = await http.get(download, headers: {'range': 'bytes=4000-'});
    expect(rest.statusCode, 206);
    expect(rest.bodyBytes, bytes.sublist(4000));

    // The SAS covers that one blob, read-only.
    final tampered = download.replace(
      queryParameters: {...download.queryParameters, 'sp': 'rw'},
    );
    expect((await http.get(tampered)).statusCode, 403);
    final other = download.replace(
      path: download.path.replaceFirst('aarch64', 'arm'),
    );
    expect((await http.get(other)).statusCode, 403);

    await storage.deletePrefix('apps/x/');
    expect((await http.get(download)).statusCode, 404);
    final kept = await http.get(await url('apps/y/patches/1/arm'));
    expect(kept.statusCode, 200);
    await storage.deletePrefix('apps/');
  });
}
