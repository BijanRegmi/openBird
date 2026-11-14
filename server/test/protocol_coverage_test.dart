import 'dart:io';
import 'dart:typed_data';

import 'package:openbird_server/openbird_server.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// Keeps the server honest about the pinned protocol (protocol/shorebird.lock):
/// every operation Shorebird's spec, client or updater uses is classified in
/// protocol/operations.yaml, and every one marked implemented is routed.
void main() {
  final root = Directory.current.parent.path;
  final registry =
      (loadYaml(File('$root/protocol/operations.yaml').readAsStringSync())
              as YamlMap)['operations']
          as YamlList;
  final classified = {
    for (final op in registry) '${op['method']} ${op['path']}': op,
  };

  final spec =
      loadYaml(File('$root/protocol/openapi.yaml').readAsStringSync())
          as YamlMap;
  final specOps = <String>{
    for (final MapEntry(key: path, value: item)
        in (spec['paths'] as YamlMap).entries)
      for (final method in (item as YamlMap).keys)
        if (const {'get', 'post', 'put', 'patch', 'delete'}.contains(method))
          '${(method as String).toUpperCase()} $path',
  };
  final clientOps = File(
    '$root/protocol/client_routes.txt',
  ).readAsLinesSync().where((l) => l.trim().isNotEmpty).toSet();

  test('every spec operation is classified', () {
    expect(
      specOps.difference(classified.keys.toSet()),
      isEmpty,
      reason: 'Classify new operations in protocol/operations.yaml',
    );
  });

  test('every client route is classified', () {
    expect(
      clientOps.difference(classified.keys.toSet()),
      isEmpty,
      reason: 'Classify new client routes in protocol/operations.yaml',
    );
  });

  test('every classified operation still exists upstream', () {
    final upstream = {...specOps, ...clientOps, 'POST /patches/events'};
    expect(
      classified.keys.toSet().difference(upstream),
      isEmpty,
      reason:
          'Shorebird removed these; drop them from operations.yaml '
          '(and keep serving them only if old clients or updaters need them)',
    );
  });

  test('implemented and stub operations are routed, and nothing else is', () {
    final routed = operations(_fakeServices())
        .where((o) => !o.path.startsWith('/uploads/'))
        .map((o) => '${o.method} ${o.path}')
        .toSet();
    final served = {
      for (final MapEntry(:key, :value) in classified.entries)
        if (value['status'] == 'implemented' || value['status'] == 'stub') key,
    };
    expect(
      served.difference(routed),
      isEmpty,
      reason: 'marked served but not routed',
    );
    expect(
      routed.difference(served),
      isEmpty,
      reason: 'routed but not marked served',
    );
  });
}

Services _fakeServices() {
  final config = Config(
    port: 0,
    databaseUrl: 'postgres://unused',
    masterKey: Uint8List(32),
    storage: FsStorageConfig('/tmp/unused'),
    stagingDir: '/tmp/unused',
  );
  return Services(
    config: config,
    db: Db.connect('postgres://u:p@localhost:1/unused'),
    storage: Storage.fromConfig(config.storage, UrlSigner(config.masterKey)),
  );
}
