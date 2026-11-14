import 'package:shelf/shelf.dart';
import 'package:shorebird_code_push_protocol/shorebird_code_push_protocol.dart';

import '../auth.dart';
import '../crypto.dart';
import '../http.dart';
import '../services.dart';

/// Organization members and invitations (spec operations).
///
/// There is no mail delivery: an invitee sees pending invitations after
/// signing in (console or `shorebird invitations`), and may sign up with
/// the invited email even when sign-up is otherwise closed.
class MembersApi {
  MembersApi(this.s);
  final Services s;

  static const _ttl = Duration(days: 14);

  Role _assignable(Role role) {
    if (role == Role.none) throw ApiError.badRequest('Pick a role.');
    return role;
  }

  Future<void> _keepAnOwner(int orgId, int userId) async {
    final row = await s.db.one(
      "SELECT count(*) FILTER (WHERE role = 'owner') AS owners, "
      " bool_or(user_id = @u AND role = 'owner') AS is_owner "
      'FROM organization_members WHERE organization_id = @o',
      {'o': orgId, 'u': userId},
    );
    if ((row!['is_owner'] as bool? ?? false) && (row['owners'] as int) <= 1) {
      throw ApiError.badRequest('An organization needs at least one owner.');
    }
  }

  Future<Response> updateOrganizationUser(Request request) async {
    final orgId = pathInt(request, 'organizationId');
    await s.access.requireOrgRole(request.principal, orgId, anyOf: adminRoles);
    final userId = pathInt(request, 'userId');
    final body = parseBody(
      await readJsonObject(request),
      UpdateOrganizationUserRequest.fromJson,
    );
    final role = _assignable(body.role);
    if (role != Role.owner) await _keepAnOwner(orgId, userId);
    final n = await s.db.execute(
      'UPDATE organization_members SET role = @r WHERE organization_id = @o AND user_id = @u',
      {'r': role.value, 'o': orgId, 'u': userId},
    );
    if (n == 0) throw ApiError.notFound('Member');
    return noContent();
  }

  Future<Response> deleteOrganizationUser(Request request) async {
    final orgId = pathInt(request, 'organizationId');
    final userId = pathInt(request, 'userId');
    // Anyone may leave; removing someone else takes an admin.
    if (userId != request.principal.userId) {
      await s.access.requireOrgRole(
        request.principal,
        orgId,
        anyOf: adminRoles,
      );
    } else {
      await s.access.requireOrgRole(request.principal, orgId);
    }
    await _keepAnOwner(orgId, userId);
    final n = await s.db.execute(
      'DELETE FROM organization_members WHERE organization_id = @o AND user_id = @u',
      {'o': orgId, 'u': userId},
    );
    if (n == 0) throw ApiError.notFound('Member');
    return noContent();
  }

  Future<Response> getOrganizationInvitations(Request request) async {
    final orgId = pathInt(request, 'organizationId');
    await s.access.requireOrgRole(request.principal, orgId);
    final rows = await s.db.query(
      'SELECT * FROM invitations WHERE organization_id = @o AND resolution IS NULL '
      'AND expires_at > now() ORDER BY created_at DESC',
      {'o': orgId},
    );
    return jsonResponse(
      GetInvitationsResponse(
        invitations: [
          for (final row in rows)
            InvitationSummary(
              id: row['id'].toString(),
              email: row['email'] as String,
              role: Role.fromJson(row['role'] as String),
              createdAt: (row['created_at'] as DateTime).toUtc(),
              expiresAt: (row['expires_at'] as DateTime).toUtc(),
            ),
        ],
      ).toJson(),
    );
  }

  Future<Response> createOrganizationInvitation(Request request) async {
    final orgId = pathInt(request, 'organizationId');
    await s.access.requireOrgRole(request.principal, orgId, anyOf: adminRoles);
    final body = parseBody(
      await readJsonObject(request),
      CreateOrganizationInvitationRequest.fromJson,
    );
    final email = body.email.trim().toLowerCase();
    final role = _assignable(body.role);
    final existing = await s.db.one(
      'SELECT id FROM users WHERE lower(email) = @e',
      {'e': email},
    );
    if (existing != null) {
      final added = await s.db.execute(
        'INSERT INTO organization_members (organization_id, user_id, role) VALUES (@o, @u, @r) '
        'ON CONFLICT DO NOTHING',
        {'o': orgId, 'u': existing['id'], 'r': role.value},
      );
      if (added == 0) throw ApiError.conflict('$email is already a member.');
      return jsonResponse(
        AddedMemberResponse(email: email, role: role).toJson(),
        status: 201,
      );
    }
    await s.db.execute(
      'UPDATE invitations SET resolution = \'revoked\', resolved_at = now() '
      'WHERE organization_id = @o AND lower(email) = @e AND resolution IS NULL',
      {'o': orgId, 'e': email},
    );
    await s.db.execute(
      'INSERT INTO invitations (id, organization_id, email, role, inviter_id, expires_at) '
      'VALUES (CAST(@id AS uuid), @o, @e, @r, @inviter, now() + make_interval(days => @days))',
      {
        'id': uuidV4(),
        'o': orgId,
        'e': email,
        'r': role.value,
        'inviter': request.principal.userId,
        'days': _ttl.inDays,
      },
    );
    return jsonResponse(
      CreateInvitationResponse(email: email).toJson(),
      status: 201,
    );
  }

  Future<Response> revokeOrganizationInvitation(Request request) async {
    final orgId = pathInt(request, 'organizationId');
    await s.access.requireOrgRole(request.principal, orgId, anyOf: adminRoles);
    final n = await s.db.execute(
      "UPDATE invitations SET resolution = 'revoked', resolved_at = now() "
      'WHERE id::text = @id AND organization_id = @o AND resolution IS NULL',
      {'id': pathString(request, 'invitationId'), 'o': orgId},
    );
    if (n == 0) throw ApiError.notFound('Invitation');
    return noContent();
  }

  static const _receivedSql =
      'SELECT i.*, o.name AS org_name, u.email AS inviter_email FROM invitations i '
      'JOIN organizations o ON o.id = i.organization_id '
      'LEFT JOIN users u ON u.id = i.inviter_id '
      'WHERE lower(i.email) = lower(@me) AND i.resolution IS NULL AND i.expires_at > now()';

  Future<Response> getReceivedInvitations(Request request) async {
    final rows = await s.db.query('$_receivedSql ORDER BY i.created_at DESC', {
      'me': request.principal.email,
    });
    return jsonResponse(
      GetReceivedInvitationsResponse(
        invitations: [
          for (final row in rows)
            ReceivedInvitation(
              id: row['id'].toString(),
              organizationId: row['organization_id'] as int,
              targetName: row['org_name'] as String,
              inviterEmail: row['inviter_email'] as String? ?? '',
              role: Role.fromJson(row['role'] as String),
              createdAt: (row['created_at'] as DateTime).toUtc(),
              expiresAt: (row['expires_at'] as DateTime).toUtc(),
            ),
        ],
      ).toJson(),
    );
  }

  Future<Map<String, dynamic>> _received(Request request) async {
    final row = await s.db.one('$_receivedSql AND i.id::text = @id', {
      'me': request.principal.email,
      'id': pathString(request, 'invitationId'),
    });
    if (row == null) throw ApiError.notFound('Invitation');
    return row;
  }

  Future<Response> getInvitation(Request request) async {
    final row = await _received(request);
    return jsonResponse(
      GetInvitationResponse(
        id: row['id'].toString(),
        organizationId: row['organization_id'] as int,
        appId: null,
        targetName: row['org_name'] as String,
        inviterEmail: row['inviter_email'] as String? ?? '',
        email: row['email'] as String,
        role: Role.fromJson(row['role'] as String),
        expiresAt: (row['expires_at'] as DateTime).toUtc(),
      ).toJson(),
    );
  }

  Future<Response> acceptInvitation(Request request) async {
    final row = await _received(request);
    await s.db.tx((tx) async {
      await tx.execute(
        r'INSERT INTO organization_members (organization_id, user_id, role) VALUES ($1, $2, $3) '
        r'ON CONFLICT (organization_id, user_id) DO UPDATE SET role = EXCLUDED.role',
        parameters: [
          row['organization_id'],
          request.principal.userId,
          row['role'],
        ],
      );
      await tx.execute(
        r"UPDATE invitations SET resolution = 'accepted', resolved_at = now() WHERE id::text = $1",
        parameters: [row['id'].toString()],
      );
    });
    return noContent();
  }

  Future<Response> declineInvitation(Request request) async {
    final row = await _received(request);
    await s.db.execute(
      "UPDATE invitations SET resolution = 'declined', resolved_at = now() WHERE id::text = @id",
      {'id': row['id'].toString()},
    );
    return noContent();
  }
}
