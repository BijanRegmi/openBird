import 'package:shelf/shelf.dart';

import 'crypto.dart';
import 'db.dart';
import 'http.dart';

/// The `sb_api_` prefix the Shorebird CLI requires of `SHOREBIRD_TOKEN`
/// before it sends it as a bearer token (`shorebird_cli/lib/src/auth/auth.dart`).
const apiKeyPrefix = 'sb_api_';

class Principal {
  Principal({required this.userId, required this.email});
  final int userId;
  final String email;
}

const _principalKey = 'openbird/principal';

extension PrincipalRequest on Request {
  Principal get principal {
    final principal = context[_principalKey] as Principal?;
    if (principal == null) throw ApiError.unauthorized();
    return principal;
  }
}

/// Roles that may change an organization's apps, releases and patches.
const writeRoles = {'owner', 'admin', 'appManager', 'developer'};
const adminRoles = {'owner', 'admin'};

/// Creates `sb_api_<random>` keys and resolves bearer tokens to users.
class ApiKeys {
  ApiKeys(this._db);
  final Db _db;

  static String hash(String key) => sha256Hex(key.codeUnits);

  Future<String> create({required int userId, required String name}) async {
    final key = '$apiKeyPrefix${randomToken(32)}';
    await _db.execute(
      'INSERT INTO api_keys (user_id, name, key_hash, prefix) '
      'VALUES (@user, @name, @hash, @prefix)',
      {
        'user': userId,
        'name': name,
        'hash': hash(key),
        'prefix': key.substring(0, 12),
      },
    );
    return key;
  }

  Future<Principal?> resolve(String key) async {
    final row = await _db.one(
      'UPDATE api_keys k SET last_used_at = now() FROM users u '
      'WHERE k.key_hash = @hash AND k.revoked_at IS NULL AND u.id = k.user_id '
      'RETURNING u.id, u.email',
      {'hash': hash(key)},
    );
    if (row == null) return null;
    return Principal(userId: row['id'] as int, email: row['email'] as String);
  }
}

const sessionCookie = 'openbird_session';

/// The header the console sends with every request. A cross-site form or
/// fetch can't set it without a CORS preflight we never grant, so requiring
/// it on cookie-authenticated writes blocks CSRF.
const consoleHeader = 'x-openbird-console';

/// Console sign-in sessions, carried in an HttpOnly cookie.
class Sessions {
  Sessions(this._db);
  final Db _db;

  static const ttl = Duration(days: 14);

  Future<String> create(int userId, {String? userAgent}) async {
    final token = randomToken(32);
    await _db.execute(
      'INSERT INTO sessions (token_hash, user_id, user_agent, expires_at) '
      'VALUES (@h, @u, @ua, now() + make_interval(days => @days))',
      {
        'h': ApiKeys.hash(token),
        'u': userId,
        'ua': userAgent,
        'days': ttl.inDays,
      },
    );
    return token;
  }

  Future<Principal?> resolve(String token) async {
    final row = await _db.one(
      'SELECT u.id, u.email FROM sessions s JOIN users u ON u.id = s.user_id '
      'WHERE s.token_hash = @h AND s.expires_at > now()',
      {'h': ApiKeys.hash(token)},
    );
    if (row == null) return null;
    return Principal(userId: row['id'] as int, email: row['email'] as String);
  }

  Future<void> revoke(String token) => _db.execute(
    'DELETE FROM sessions WHERE token_hash = @h',
    {'h': ApiKeys.hash(token)},
  );
}

String? cookieValue(Request request, String name) {
  for (final part in (request.headers['cookie'] ?? '').split(';')) {
    final i = part.indexOf('=');
    if (i > 0 && part.substring(0, i).trim() == name) {
      return part.substring(i + 1).trim();
    }
  }
  return null;
}

/// Resolves the caller from `Authorization: Bearer sb_api_…` (CLI, CI) or
/// the console session cookie, for every route except those [isPublic]
/// names, which devices and signed URLs use. [isOptional] routes run
/// without a principal when there is none (console sign-in).
Middleware authMiddleware(
  ApiKeys keys,
  Sessions sessions, {
  required bool Function(Request) isPublic,
  bool Function(Request)? isOptional,
}) {
  return (inner) => (request) async {
    if (isPublic(request)) return inner(request);
    final optional = isOptional?.call(request) ?? false;
    Principal? principal;
    final header = request.headers['authorization'];
    if (header != null) {
      final match = RegExp(
        r'^Bearer\s+(.+)$',
        caseSensitive: false,
      ).firstMatch(header);
      final token = match?.group(1)?.trim();
      if (token != null && token.startsWith(apiKeyPrefix)) {
        principal = await keys.resolve(token);
      }
      if (principal == null) return ApiError.unauthorized().toResponse();
    } else {
      final cookie = cookieValue(request, sessionCookie);
      if (cookie != null) {
        const safe = {'GET', 'HEAD', 'OPTIONS'};
        if (!safe.contains(request.method) &&
            request.headers[consoleHeader] == null) {
          return ApiError.forbidden(
            'Missing $consoleHeader header.',
          ).toResponse();
        }
        principal = await sessions.resolve(cookie);
      }
    }
    if (principal == null) {
      if (optional) return inner(request);
      return ApiError.unauthorized().toResponse();
    }
    return inner(request.change(context: {_principalKey: principal}));
  };
}

extension MaybePrincipal on Request {
  Principal? get maybePrincipal => context[_principalKey] as Principal?;
}

/// Membership checks shared by the handlers.
class Access {
  Access(this._db);
  final Db _db;

  Future<String?> orgRole(int userId, int organizationId) async {
    final row = await _db.one(
      'SELECT role FROM organization_members WHERE user_id = @u AND organization_id = @o',
      {'u': userId, 'o': organizationId},
    );
    return row?['role'] as String?;
  }

  Future<String> requireOrgRole(
    Principal principal,
    int organizationId, {
    Set<String>? anyOf,
  }) async {
    final role = await orgRole(principal.userId, organizationId);
    if (role == null) throw ApiError.notFound('Organization');
    if (anyOf != null && !anyOf.contains(role)) throw ApiError.forbidden();
    return role;
  }

  /// Returns the app row after checking the principal belongs to its
  /// organization (and holds one of [anyOf], when given). Apps outside the
  /// principal's organizations are reported as missing, not forbidden.
  Future<Map<String, dynamic>> requireApp(
    Principal principal,
    String appId, {
    Set<String>? anyOf,
  }) async {
    final row = await _db.one(
      'SELECT a.*, m.role FROM apps a '
      'JOIN organization_members m ON m.organization_id = a.organization_id '
      'WHERE a.id = @id AND m.user_id = @u',
      {'id': appId, 'u': principal.userId},
    );
    if (row == null) throw ApiError.notFound('App');
    if (anyOf != null && !anyOf.contains(row['role'])) {
      throw ApiError.forbidden();
    }
    return row;
  }

  Future<Map<String, dynamic>> requireRelease(
    String appId,
    int releaseId,
  ) async {
    final row = await _db.one(
      'SELECT * FROM releases WHERE id = @id AND app_id = @app',
      {'id': releaseId, 'app': appId},
    );
    if (row == null) throw ApiError.notFound('Release');
    return row;
  }

  /// A patch joined with its release, scoped to [appId].
  Future<Map<String, dynamic>> requirePatch(String appId, int patchId) async {
    final row = await _db.one(
      'SELECT p.*, r.app_id, r.version AS release_version FROM patches p '
      'JOIN releases r ON r.id = p.release_id '
      'WHERE p.id = @id AND r.app_id = @app',
      {'id': patchId, 'app': appId},
    );
    if (row == null) throw ApiError.notFound('Patch');
    return row;
  }
}
