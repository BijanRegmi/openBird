import 'package:shelf/shelf.dart';
import 'package:shorebird_code_push_protocol/shorebird_code_push_protocol.dart';

import '../auth.dart';
import '../http.dart';
import '../services.dart';
import 'mappers.dart';

/// Users, organizations, and the account-level routes the CLI touches
/// (plan, usage, notification preferences, invitations).
class AccountApi {
  AccountApi(this.s);
  final Services s;

  Future<Response> getCurrentUser(Request request) async {
    final row = await s.db.one('SELECT * FROM users WHERE id = @id', {
      'id': request.principal.userId,
    });
    if (row == null) throw ApiError.notFound('User');
    return jsonResponse(
      PrivateUser(
        id: row['id'] as int,
        email: row['email'] as String,
        displayName: row['display_name'] as String?,
        jwtIssuer: s.originFor(request).toString(),
      ).toJson(),
    );
  }

  Future<Response> updateCurrentUser(Request request) async {
    final body = parseBody(
      await readJsonObject(request),
      UpdateUserRequest.fromJson,
    );
    if (body.displayName != null) {
      await s.db.execute('UPDATE users SET display_name = @n WHERE id = @id', {
        'n': body.displayName,
        'id': request.principal.userId,
      });
    }
    return noContent();
  }

  Future<Response> getOrganizationMemberships(Request request) async {
    final rows = await s.db.query(
      'SELECT o.*, m.role FROM organizations o '
      'JOIN organization_members m ON m.organization_id = o.id '
      'WHERE m.user_id = @u ORDER BY o.id',
      {'u': request.principal.userId},
    );
    return jsonResponse(
      GetOrganizationsResponse(
        organizations: [
          for (final row in rows)
            OrganizationMembership(
              organization: organizationFrom(row),
              role: roleFrom(row['role']),
            ),
        ],
        totalCount: rows.length,
      ).toJson(),
    );
  }

  Future<Response> createOrganization(Request request) async {
    final body = parseBody(
      await readJsonObject(request),
      CreateOrganizationRequest.fromJson,
    );
    final name = body.name.trim();
    if (name.isEmpty) {
      throw ApiError.badRequest('Organization name is required.');
    }
    final org = await s.db.tx((tx) async {
      final org = (await tx.execute(
        r"INSERT INTO organizations (name, organization_type) VALUES ($1, 'team') RETURNING *",
        parameters: [name],
      )).first.toColumnMap();
      await tx.execute(
        r"INSERT INTO organization_members (organization_id, user_id, role) VALUES ($1, $2, 'owner')",
        parameters: [org['id'], request.principal.userId],
      );
      return org;
    });
    return jsonResponse(organizationFrom(org).toJson(), status: 201);
  }

  Future<Response> getOrganization(Request request) async {
    final orgId = pathInt(request, 'organizationId');
    await s.access.requireOrgRole(request.principal, orgId);
    final row = await s.db.one('SELECT * FROM organizations WHERE id = @id', {
      'id': orgId,
    });
    return jsonResponse(organizationFrom(row!).toJson());
  }

  Future<Response> updateOrganization(Request request) async {
    final orgId = pathInt(request, 'organizationId');
    await s.access.requireOrgRole(request.principal, orgId, anyOf: adminRoles);
    final body = parseBody(
      await readJsonObject(request),
      UpdateOrganizationRequest.fromJson,
    );
    final row = await s.db.one(
      'UPDATE organizations SET name = @n, updated_at = now() WHERE id = @id RETURNING *',
      {'n': body.name, 'id': orgId},
    );
    return jsonResponse(organizationFrom(row!).toJson());
  }

  Future<Response> getOrganizationApps(Request request) async {
    final orgId = pathInt(request, 'organizationId');
    await s.access.requireOrgRole(request.principal, orgId);
    final q = request.url.queryParameters['q']?.toLowerCase();
    final platform = request.url.queryParameters['platform'];
    final ids = [
      for (final row in await s.db.query(
        'SELECT id FROM apps WHERE organization_id = @o',
        {'o': orgId},
      ))
        row['id'] as String,
    ];
    var apps = await loadAppMetadata(s.db, ids);
    if (q != null && q.isNotEmpty) {
      apps = apps
          .where((a) => a.displayName.toLowerCase().contains(q))
          .toList();
    }
    if (platform != null) {
      apps = apps
          .where((a) => a.platforms?.any((p) => p.value == platform) ?? false)
          .toList();
    }
    return jsonResponse(
      GetOrganizationAppsResponse(
        apps: apps,
        totalCount: apps.length,
        platforms: {for (final a in apps) ...?a.platforms}.toList(),
      ).toJson(),
    );
  }

  Future<Response> getOrganizationUsers(Request request) async {
    final orgId = pathInt(request, 'organizationId');
    await s.access.requireOrgRole(request.principal, orgId);
    final rows = await s.db.query(
      'SELECT u.*, m.role FROM users u JOIN organization_members m ON m.user_id = u.id '
      'WHERE m.organization_id = @o ORDER BY u.id',
      {'o': orgId},
    );
    return jsonResponse(
      GetOrganizationUsersResponse(
        users: [
          for (final row in rows)
            OrganizationUser(
              user: PublicUser(
                id: row['id'] as int,
                email: row['email'] as String,
                displayName: row['display_name'] as String?,
              ),
              role: roleFrom(row['role']),
            ),
        ],
        totalCount: rows.length,
      ).toJson(),
    );
  }

  /// Self-hosted: one unlimited plan. `shorebird account` reads `level`.
  Future<Response> getPlan(Request request) async =>
      jsonResponse(_plan().toJson());

  Future<Response> getOrganizationPlan(Request request) async {
    await s.access.requireOrgRole(
      request.principal,
      pathInt(request, 'organizationId'),
    );
    return jsonResponse(_plan().toJson());
  }

  Plan _plan() {
    final now = DateTime.now().toUtc();
    return Plan(
      name: 'Self-hosted',
      currency: 'usd',
      basePrice: 0,
      baseInstallCount: 0,
      patchInstallCredit: 0,
      patchOverageLimit: null,
      pricePerOverageInstall: null,
      currentPeriodStart: DateTime.utc(now.year, now.month),
      currentPeriodEnd: DateTime.utc(now.year, now.month + 1),
      cancelAtPeriodEnd: false,
      isTiered: false,
      isTrial: false,
      baseStanding: 'good',
      overageStanding: 'good',
      overageState: 'none',
      overageBlockedBy: null,
      overagePeriodStart: null,
      overagePeriodEnd: null,
      features: const [],
      level: 'self_hosted',
      minimumReleasesKept: null,
      maxTeamSize: null,
      availableRoles: Role.values.where((r) => r != Role.none).toList(),
      billingInterval: null,
      billingIntervalCount: null,
      subscriberSince: null,
    );
  }

  Future<Response> getUsage(Request request) async {
    final orgIds = [
      for (final row in await s.db.query(
        'SELECT organization_id FROM organization_members WHERE user_id = @u',
        {'u': request.principal.userId},
      ))
        row['organization_id'] as int,
    ];
    return jsonResponse((await _usage(orgIds)).toJson());
  }

  Future<Response> getOrganizationUsage(Request request) async {
    final orgId = pathInt(request, 'organizationId');
    await s.access.requireOrgRole(request.principal, orgId);
    return jsonResponse((await _usage([orgId])).toJson());
  }

  /// Patch installs this calendar month, counted from updater events.
  Future<GetUsageResponse> _usage(List<int> orgIds) async {
    final rows = await s.db.query(
      'SELECT a.id, a.display_name, '
      " (SELECT count(*) FROM patch_events e WHERE e.app_id = a.id AND e.type = '__patch_install__' "
      "   AND e.received_at >= date_trunc('month', now())) AS installs "
      'FROM apps a WHERE a.organization_id = ANY(@orgs) ORDER BY a.created_at',
      {'orgs': orgIds},
    );
    final apps = [
      for (final row in rows)
        AppUsage(
          id: row['id'] as String,
          name: row['display_name'] as String,
          patchInstallCount: row['installs'] as int,
        ),
    ];
    final total = apps.fold<int>(0, (sum, a) => sum + a.patchInstallCount);
    return GetUsageResponse(
      apps: apps,
      reportedOverage: null,
      position: AccountPosition(
        includedInstalls: total,
        installs: total,
        includedInstallsUsed: total,
        includedExhausted: false,
        overageInstalls: 0,
        installCeiling: null,
        remainingInstalls: null,
        atCeiling: false,
        nearingLimit: false,
        consumingOverage: false,
        accruedOverageAmount: null,
      ),
    );
  }

  // Stubs: neutral answers so the CLI commands that read them still work.

  Future<Response> getNotificationPreferences(Request request) async =>
      jsonResponse(
        const GetNotificationPreferencesResponse(
          preferences: NotificationPreferences(
            areEmailNotificationsEnabled: false,
          ),
        ).toJson(),
      );

  Future<Response> updateNotificationPreferences(Request request) async =>
      noContent();

  Future<Response> getOrganizationAuditLogs(Request request) async {
    await s.access.requireOrgRole(
      request.principal,
      pathInt(request, 'organizationId'),
    );
    return jsonResponse(
      const GetOrganizationAuditLogsResponse(data: []).toJson(),
    );
  }
}
