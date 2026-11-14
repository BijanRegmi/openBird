import 'dart:io';

import 'package:openbird_server/openbird_server.dart';
import 'package:logging/logging.dart';
import 'package:shelf/shelf_io.dart' as io;

Future<void> main() async {
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((r) {
    stderr.writeln(
      '${r.time.toIso8601String()} ${r.level.name} ${r.loggerName}: ${r.message}'
      '${r.error != null ? '\n${r.error}\n${r.stackTrace}' : ''}',
    );
  });
  final config = Config.fromEnvironment();
  final db = Db.connect(config.databaseUrl);
  await db.migrate(config.migrationsDir);
  final services = Services(
    config: config,
    db: db,
    storage: Storage.fromConfig(config.storage, UrlSigner(config.masterKey)),
  );
  await services.storage.init();
  await Directory(config.stagingDir).create(recursive: true);
  final server = await io.serve(
    buildHandler(services),
    InternetAddress.anyIPv4,
    config.port,
  );
  // Uploads are streamed to disk; don't buffer or compress responses.
  server.autoCompress = false;
  Logger('server').info('Listening on :${server.port}');
  ProcessSignal.sigterm.watch().listen((_) async {
    await server.close();
    await db.close();
    exit(0);
  });
}
