import 'dart:io';

import 'package:openbird_server/openbird_server.dart';
import 'package:openbird_server/src/crypto.dart';
import 'package:logging/logging.dart';
import 'package:shelf/shelf_io.dart' as io;

/// A server on an ephemeral port over a fresh TEST_DATABASE_URL schema, with
/// one user (in a personal organization) and their API key. Artifacts go to
/// a temporary directory, or to Azurite with TEST_STORAGE=azure.
class TestServer {
  TestServer._(this._http, this.db, this.dir, this.apiKey, this.orgId);

  static Future<TestServer> start() async {
    Logger.root.onRecord
        .where((r) => r.level >= Level.WARNING)
        .listen(
          (r) => print(
            '${r.level} ${r.message}\n${r.error ?? ''}\n${r.stackTrace ?? ''}',
          ),
        );
    final url =
        Platform.environment['TEST_DATABASE_URL'] ??
        'postgres://openbird:openbird@localhost:54329/openbird_test?sslmode=disable';
    final db = Db.connect(url);
    await db.pool.execute('DROP SCHEMA public CASCADE');
    await db.pool.execute('CREATE SCHEMA public');
    await db.migrate('migrations');
    final dir = await Directory.systemTemp.createTemp('openbird_test');
    final config = Config(
      port: 0,
      databaseUrl: url,
      masterKey: randomBytes(32),
      // TEST_STORAGE=azure runs every server test on Azurite.
      storage: Platform.environment['TEST_STORAGE'] == 'azure'
          ? AzureBlobStorageConfig.fromConnectionString(
              'UseDevelopmentStorage=true',
              container: 'openbird-server-test',
            )
          : FsStorageConfig('${dir.path}/storage'),
      stagingDir: '${dir.path}/staging',
    );
    final services = Services(
      config: config,
      db: db,
      storage: Storage.fromConfig(config.storage, UrlSigner(config.masterKey)),
    );
    await services.storage.init();
    final user = await db.one(
      "INSERT INTO users (email, display_name) VALUES ('dev@example.com', 'Dev') RETURNING id",
    );
    final org = await db.one(
      "INSERT INTO organizations (name, organization_type) VALUES ('Dev', 'personal') RETURNING id",
    );
    await db.execute(
      "INSERT INTO organization_members (organization_id, user_id, role) VALUES (@o, @u, 'owner')",
      {'o': org!['id'], 'u': user!['id']},
    );
    final key = await ApiKeys(
      db,
    ).create(userId: user['id'] as int, name: 'test');
    final http = await io.serve(
      buildHandler(services),
      InternetAddress.loopbackIPv4,
      0,
    );
    http.autoCompress = false;
    return TestServer._(http, db, dir, key, org['id'] as int);
  }

  final HttpServer _http;
  final Db db;
  final Directory dir;
  final String apiKey;
  final int orgId;

  Uri get uri => Uri.parse('http://localhost:${_http.port}');

  Future<void> stop() async {
    await _http.close(force: true);
    await db.close();
    await dir.delete(recursive: true);
  }
}
