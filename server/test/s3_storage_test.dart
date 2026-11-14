import 'dart:io';

import 'package:openbird_server/openbird_server.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

/// Runs against the docker-compose S3 service (or S3_TEST_ENDPOINT); skipped when
/// none is reachable.
void main() {
  final endpoint = Platform.environment['S3_TEST_ENDPOINT'] ?? 'localhost';
  final port = int.parse(Platform.environment['S3_TEST_PORT'] ?? '9000');
  Future<bool> reachable() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
    try {
      final response = await (await client.getUrl(
        Uri.parse('http://$endpoint:$port/'),
      )).close();
      await response.drain<void>();
      return true;
    } on Object {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  test('put, presigned download with Range, delete prefix', () async {
    if (!await reachable()) {
      markTestSkipped('no S3 endpoint at $endpoint:$port');
      return;
    }
    final storage = S3Storage(
      S3StorageConfig(
        endpoint: endpoint,
        port: port,
        useSsl: false,
        accessKey: 'openbird',
        secretKey: 'openbird-secret',
        bucket: 'openbird-test',
      ),
    );
    await storage.init();
    final dir = await Directory.systemTemp.createTemp('s3');
    addTearDown(() => dir.delete(recursive: true));
    final bytes = List<int>.generate(5000, (i) => i & 0xff);
    final file = File('${dir.path}/f')..writeAsBytesSync(bytes);
    await storage.putFile('apps/x/patch.bin', file);

    final url = Uri.parse(
      await storage.downloadUrl(
        'apps/x/patch.bin',
        origin: Uri.parse('http://unused'),
        ttl: const Duration(minutes: 5),
      ),
    );
    final full = await http.get(url);
    expect(full.bodyBytes, bytes);
    final rest = await http.get(url, headers: {'range': 'bytes=4000-'});
    expect(rest.statusCode, 206);
    expect(rest.bodyBytes, bytes.sublist(4000));

    await storage.deletePrefix('apps/x/');
    expect((await http.get(url)).statusCode, 404);
  });
}
