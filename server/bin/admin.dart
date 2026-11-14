import 'dart:io';

import 'package:args/args.dart';
import 'package:openbird_server/openbird_server.dart';

/// Operator commands, run against DATABASE_URL:
///
///   dart run bin/admin.dart create-user --email you@example.com [--name "You"]
///   dart run bin/admin.dart create-key --email you@example.com [--name ci]
///   dart run bin/admin.dart revoke-key --prefix sb_api_abcd
///   dart run bin/admin.dart set-password --email you@example.com --password '…'
///   dart run bin/admin.dart list-users
Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addCommand(
      'create-user',
      ArgParser()
        ..addOption('email', mandatory: true)
        ..addOption('name'),
    )
    ..addCommand(
      'create-key',
      ArgParser()
        ..addOption('email', mandatory: true)
        ..addOption('name', defaultsTo: 'cli'),
    )
    ..addCommand(
      'revoke-key',
      ArgParser()..addOption('prefix', mandatory: true),
    )
    ..addCommand(
      'set-password',
      ArgParser()
        ..addOption('email', mandatory: true)
        ..addOption('password', mandatory: true),
    )
    ..addCommand('list-users');
  final ArgResults results;
  try {
    results = parser.parse(args);
  } on FormatException catch (e) {
    stderr.writeln(
      '${e.message}\n\nCommands: ${parser.commands.keys.join(', ')}',
    );
    exit(64);
  }
  final command = results.command;
  if (command == null) {
    stderr.writeln('Commands: ${parser.commands.keys.join(', ')}');
    exit(64);
  }
  final url = Platform.environment['DATABASE_URL'];
  if (url == null) {
    stderr.writeln('DATABASE_URL must be set');
    exit(64);
  }
  final db = Db.connect(url);
  await db.migrate(Platform.environment['MIGRATIONS_DIR'] ?? 'migrations');
  try {
    switch (command.name) {
      case 'create-user':
        final email = (command['email'] as String).trim().toLowerCase();
        final name = command['name'] as String?;
        final userId = await db.tx((tx) async {
          final user =
              (await tx.execute(
                    r'INSERT INTO users (email, display_name) VALUES ($1, $2) RETURNING id',
                    parameters: [email, name],
                  )).first[0]
                  as int;
          final org =
              (await tx.execute(
                    r"INSERT INTO organizations (name, organization_type) VALUES ($1, 'personal') RETURNING id",
                    parameters: [name ?? email],
                  )).first[0]
                  as int;
          await tx.execute(
            r"INSERT INTO organization_members (organization_id, user_id, role) VALUES ($1, $2, 'owner')",
            parameters: [org, user],
          );
          return user;
        });
        final key = await ApiKeys(db).create(userId: userId, name: 'initial');
        stdout.writeln(
          'Created user $email (id $userId) with a personal organization.',
        );
        stdout.writeln('API key (shown once):\n$key');
      case 'create-key':
        final email = (command['email'] as String).trim().toLowerCase();
        final user = await db.one('SELECT id FROM users WHERE email = @e', {
          'e': email,
        });
        if (user == null) throw StateError('No user $email');
        stdout.writeln(
          await ApiKeys(
            db,
          ).create(userId: user['id'] as int, name: command['name'] as String),
        );
      case 'revoke-key':
        final n = await db.execute(
          'UPDATE api_keys SET revoked_at = now() WHERE prefix = @p AND revoked_at IS NULL',
          {'p': command['prefix']},
        );
        stdout.writeln('Revoked $n key(s).');
      case 'set-password':
        final password = command['password'] as String;
        if (password.length < 10) {
          throw StateError('Passwords need at least 10 characters.');
        }
        final n = await db.execute(
          'UPDATE users SET password_hash = @h WHERE lower(email) = @e',
          {
            'h': PasswordHasher.hash(password),
            'e': (command['email'] as String).trim().toLowerCase(),
          },
        );
        stdout.writeln(n == 0 ? 'No such user.' : 'Password set.');
      case 'list-users':
        for (final row in await db.query(
          'SELECT u.id, u.email, count(k.id) FILTER (WHERE k.revoked_at IS NULL) AS keys '
          'FROM users u LEFT JOIN api_keys k ON k.user_id = u.id GROUP BY u.id ORDER BY u.id',
        )) {
          stdout.writeln('${row['id']}\t${row['email']}\tkeys: ${row['keys']}');
        }
    }
  } finally {
    await db.close();
  }
}
