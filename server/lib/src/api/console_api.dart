import 'package:shelf/shelf.dart';

import '../auth.dart';
import '../crypto.dart';
import '../http.dart';
import '../services.dart';

/// `/console/v1`: what the web console needs beyond Shorebird's protocol
/// (sign-in, API keys, build history, device event feed). Kept out of
/// `/api/v1` so it can never collide with a future Shorebird operation.
class ConsoleApi {
  ConsoleApi(this.s);
  final Services s;

  Future<bool> _signupAllowed() async {
    if (s.config.allowSignup) return true;
    final row = await s.db.one('SELECT count(*) AS n FROM users');
    return (row!['n'] as int) == 0;
  }

  Response _withSession(Response response, String token, {Duration? maxAge}) {
    final attrs = [
      '$sessionCookie=$token',
      'Path=/',
      'HttpOnly',
      'SameSite=Lax',
      'Max-Age=${(maxAge ?? Sessions.ttl).inSeconds}',
      if (s.config.secureCookies) 'Secure',
    ];
    return response.change(headers: {'set-cookie': attrs.join('; ')});
  }

  Future<Map<String, dynamic>> _me(int userId) async {
    final user = await s.db.one(
      'SELECT id, email, display_name, created_at, password_hash IS NOT NULL AS has_password '
      'FROM users WHERE id = @id',
      {'id': userId},
    );
    final keys = await s.db.one(
      'SELECT count(*) AS n FROM invitations i JOIN users u ON lower(u.email) = lower(i.email) '
      'WHERE u.id = @id AND i.resolution IS NULL AND i.expires_at > now()',
      {'id': userId},
    );
    return {
      'id': user!['id'],
      'email': user['email'],
      'display_name': user['display_name'],
      'created_at': (user['created_at'] as DateTime).toUtc().toIso8601String(),
      'has_password': user['has_password'],
      'pending_invitations': keys!['n'],
    };
  }

  Future<Response> config(Request request) async => jsonResponse({
    'signup_allowed': await _signupAllowed(),
    'api_base_url': s.originFor(request).toString(),
  });

  Future<Response> session(Request request) async {
    final principal = request.maybePrincipal;
    if (principal == null) throw ApiError.unauthorized('Not signed in.');
    return jsonResponse(await _me(principal.userId));
  }

  Future<Response> login(Request request) async {
    final body = await readJsonObject(request);
    final email = (body['email'] as String? ?? '').trim().toLowerCase();
    final password = body['password'] as String? ?? '';
    final user = await s.db.one(
      'SELECT id, password_hash FROM users WHERE lower(email) = @e',
      {'e': email},
    );
    final hash = user?['password_hash'] as String?;
    if (user == null ||
        hash == null ||
        !PasswordHasher.verify(password, hash)) {
      throw ApiError.unauthorized('Wrong email or password.');
    }
    final token = await s.sessions.create(
      user['id'] as int,
      userAgent: request.headers['user-agent'],
    );
    return _withSession(jsonResponse(await _me(user['id'] as int)), token);
  }

  /// Creates an account with a personal organization. Allowed for the first
  /// account, with ALLOW_SIGNUP, or for an email that has a pending invitation.
  Future<Response> signup(Request request) async {
    final body = await readJsonObject(request);
    final email = (body['email'] as String? ?? '').trim().toLowerCase();
    final password = body['password'] as String? ?? '';
    final name = (body['name'] as String?)?.trim();
    if (!RegExp(r'^[^@\s]+@[^@\s]+$').hasMatch(email)) {
      throw ApiError.badRequest('Enter a valid email address.');
    }
    if (password.length < 10) {
      throw ApiError.badRequest('Passwords need at least 10 characters.');
    }
    final invited = await s.db.one(
      'SELECT 1 FROM invitations WHERE lower(email) = @e AND resolution IS NULL AND expires_at > now()',
      {'e': email},
    );
    if (!await _signupAllowed() && invited == null) {
      throw ApiError.forbidden(
        'Sign-up is closed. Ask an admin to invite you.',
      );
    }
    final userId = await s.db.tx((tx) async {
      final existing = await tx.execute(
        r'SELECT id, password_hash FROM users WHERE lower(email) = $1',
        parameters: [email],
      );
      if (existing.isNotEmpty) {
        // Accounts made with bin/admin.dart have no password yet; claiming
        // one needs the operator, not the sign-up form.
        throw ApiError.conflict('An account with this email already exists.');
      }
      final user =
          (await tx.execute(
                r'INSERT INTO users (email, display_name, password_hash) VALUES ($1, $2, $3) RETURNING id',
                parameters: [
                  email,
                  name?.isEmpty ?? true ? null : name,
                  PasswordHasher.hash(password),
                ],
              )).first[0]
              as int;
      final org =
          (await tx.execute(
                r"INSERT INTO organizations (name, organization_type) VALUES ($1, 'personal') RETURNING id",
                parameters: [name?.isEmpty ?? true ? email : name],
              )).first[0]
              as int;
      await tx.execute(
        r"INSERT INTO organization_members (organization_id, user_id, role) VALUES ($1, $2, 'owner')",
        parameters: [org, user],
      );
      return user;
    });
    final token = await s.sessions.create(
      userId,
      userAgent: request.headers['user-agent'],
    );
    return _withSession(jsonResponse(await _me(userId), status: 201), token);
  }

  Future<Response> logout(Request request) async {
    final token = cookieValue(request, sessionCookie);
    if (token != null) await s.sessions.revoke(token);
    return _withSession(noContent(), '', maxAge: Duration.zero);
  }

  Future<Response> changePassword(Request request) async {
    final userId = request.principal.userId;
    final body = await readJsonObject(request);
    final current = body['current_password'] as String? ?? '';
    final next = body['new_password'] as String? ?? '';
    if (next.length < 10) {
      throw ApiError.badRequest('Passwords need at least 10 characters.');
    }
    final row = await s.db.one(
      'SELECT password_hash FROM users WHERE id = @id',
      {'id': userId},
    );
    final hash = row!['password_hash'] as String?;
    if (hash != null && !PasswordHasher.verify(current, hash)) {
      throw ApiError.badRequest('The current password is wrong.');
    }
    await s.db.execute('UPDATE users SET password_hash = @h WHERE id = @id', {
      'h': PasswordHasher.hash(next),
      'id': userId,
    });
    return noContent();
  }

  // API keys: what users set as SHOREBIRD_TOKEN.

  Future<Response> listApiKeys(Request request) async {
    final rows = await s.db.query(
      'SELECT id, name, prefix, created_at, last_used_at FROM api_keys '
      'WHERE user_id = @u AND revoked_at IS NULL ORDER BY created_at DESC',
      {'u': request.principal.userId},
    );
    return jsonResponse([
      for (final row in rows)
        {
          'id': row['id'],
          'name': row['name'],
          'prefix': row['prefix'],
          'created_at': (row['created_at'] as DateTime)
              .toUtc()
              .toIso8601String(),
          'last_used_at': (row['last_used_at'] as DateTime?)
              ?.toUtc()
              .toIso8601String(),
        },
    ]);
  }

  Future<Response> createApiKey(Request request) async {
    final body = await readJsonObject(request);
    final name = (body['name'] as String? ?? '').trim();
    if (name.isEmpty || name.length > 64) {
      throw ApiError.badRequest('Name the key (up to 64 characters).');
    }
    final key = await s.apiKeys.create(
      userId: request.principal.userId,
      name: name,
    );
    return jsonResponse({'name': name, 'key': key}, status: 201);
  }

  Future<Response> revokeApiKey(Request request) async {
    final n = await s.db.execute(
      'UPDATE api_keys SET revoked_at = now() WHERE id = @id AND user_id = @u AND revoked_at IS NULL',
      {'id': pathInt(request, 'keyId'), 'u': request.principal.userId},
    );
    if (n == 0) throw ApiError.notFound('API key');
    return noContent();
  }

  // Per-app views the protocol doesn't cover.

  Future<Response> buildRuns(Request request) async {
    final appId = pathString(request, 'appId');
    await s.access.requireApp(request.principal, appId);
    final rows = await s.db.query(
      'SELECT id, run_id, command, platform, outcome, payload, created_at FROM build_runs '
      'WHERE app_id = @a ORDER BY created_at DESC LIMIT 200',
      {'a': appId},
    );
    return jsonResponse([
      for (final row in rows)
        () {
          final p = row['payload'] as Map<String, dynamic>;
          return {
            'id': row['id'],
            'run_id': row['run_id'],
            'command': row['command'],
            'platform': row['platform'],
            'outcome': row['outcome'],
            'reason': p['reason'],
            'release_id': p['release_id'],
            'patch_id': p['patch_id'],
            'duration_ms': p['duration_ms'],
            'dry_run': p['dry_run'],
            'started_at': p['started_at'],
            'metadata': p['metadata'],
            'build_flags': p['build_flags'],
            'created_at': (row['created_at'] as DateTime)
                .toUtc()
                .toIso8601String(),
          };
        }(),
    ]);
  }

  Future<Response> events(Request request) async {
    final appId = pathString(request, 'appId');
    await s.access.requireApp(request.principal, appId);
    final q = request.url.queryParameters;
    final limit = (int.tryParse(q['limit'] ?? '') ?? 100).clamp(1, 500);
    final rows = await s.db.query(
      'SELECT id, type, release_version, patch_number, platform, arch, message, failure_category, '
      ' occurred_at, left(client_id, 8) AS client FROM patch_events WHERE app_id = @a '
      "${q['type'] != null ? 'AND type = @type ' : ''}"
      'ORDER BY occurred_at DESC, id DESC LIMIT @limit',
      {'a': appId, 'limit': limit, 'type': ?q['type']},
    );
    return jsonResponse([
      for (final row in rows)
        {
          ...row,
          'occurred_at': (row['occurred_at'] as DateTime)
              .toUtc()
              .toIso8601String(),
        },
    ]);
  }

  /// Headline numbers for the app overview.
  Future<Response> summary(Request request) async {
    final appId = pathString(request, 'appId');
    await s.access.requireApp(request.principal, appId);
    final row = await s.db.one(
      'SELECT '
      ' (SELECT count(*) FROM releases WHERE app_id = @a) AS releases, '
      ' (SELECT count(*) FROM patches p JOIN releases r ON r.id = p.release_id WHERE r.app_id = @a) AS patches, '
      " (SELECT count(*) FROM devices WHERE app_id = @a AND last_seen >= now() - interval '30 days') AS active_devices_30d, "
      " (SELECT count(*) FROM devices WHERE app_id = @a AND last_seen >= now() - interval '1 day') AS active_devices_24h, "
      " (SELECT count(*) FROM patch_events WHERE app_id = @a AND type = '__patch_install__' "
      "   AND occurred_at >= now() - interval '30 days') AS installs_30d, "
      " (SELECT count(*) FROM patch_events WHERE app_id = @a AND type IN ('__patch_install_failure__', '__patch_update_failure__') "
      "   AND occurred_at >= now() - interval '30 days') AS failures_30d, "
      ' (SELECT count(*) FROM channels WHERE app_id = @a) AS channels',
      {'a': appId},
    );
    return jsonResponse(row);
  }
}
