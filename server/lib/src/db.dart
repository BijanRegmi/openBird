import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:postgres/postgres.dart';

final _log = Logger('db');

/// Thin wrapper over a Postgres pool with named-parameter helpers.
class Db {
  Db(this.pool);

  factory Db.connect(String url) => Db(Pool.withUrl(url));

  final Pool pool;

  Future<List<Map<String, dynamic>>> query(
    String sql, [
    Map<String, Object?> params = const {},
  ]) => queryIn(pool, sql, params);

  Future<Map<String, dynamic>?> one(
    String sql, [
    Map<String, Object?> params = const {},
  ]) async => (await query(sql, params)).firstOrNull;

  Future<int> execute(
    String sql, [
    Map<String, Object?> params = const {},
  ]) async {
    final result = await pool.execute(Sql.named(sql), parameters: params);
    return result.affectedRows;
  }

  Future<R> tx<R>(Future<R> Function(TxSession tx) body) => pool.runTx(body);

  Future<void> close() => pool.close();

  /// Applies every `*.sql` file in [directory] not yet recorded in
  /// `schema_migrations`, in name order, each in its own transaction.
  Future<void> migrate(String directory) async {
    await pool.execute(
      'CREATE TABLE IF NOT EXISTS schema_migrations ('
      'version TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT now())',
    );
    final applied = {
      for (final row in await query('SELECT version FROM schema_migrations'))
        row['version'] as String,
    };
    final files =
        Directory(directory)
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.sql'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      final version = p.basenameWithoutExtension(file.path);
      if (applied.contains(version)) continue;
      _log.info('Applying migration $version');
      await pool.runTx((tx) async {
        await tx.execute(file.readAsStringSync(), queryMode: QueryMode.simple);
        await tx.execute(
          Sql.named('INSERT INTO schema_migrations (version) VALUES (@v)'),
          parameters: {'v': version},
        );
      });
    }
  }
}

/// Runs [sql] with named parameters on [session] (the pool or a transaction)
/// and returns rows as column maps.
Future<List<Map<String, dynamic>>> queryIn(
  Session session,
  String sql, [
  Map<String, Object?> params = const {},
]) async {
  final result = await session.execute(Sql.named(sql), parameters: params);
  return [for (final row in result) row.toColumnMap()];
}

Future<Map<String, dynamic>?> oneIn(
  Session session,
  String sql, [
  Map<String, Object?> params = const {},
]) async => (await queryIn(session, sql, params)).firstOrNull;
