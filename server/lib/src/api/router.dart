import 'dart:io';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';

import '../auth.dart';
import '../http.dart';
import '../services.dart';
import 'account_api.dart';
import 'apps_api.dart';
import 'console_api.dart';
import 'members_api.dart';
import 'metrics_api.dart';
import 'patches_api.dart';
import 'releases_api.dart';
import 'transfer_api.dart';
import 'updater_api.dart';

final _log = Logger('api');

/// One protocol operation this server routes. [path] uses the openapi
/// template syntax (`/apps/{appId}`) relative to `/api/v1`, so
/// test/protocol_coverage_test.dart can compare it with the pinned spec.
class Operation {
  const Operation(
    this.id,
    this.method,
    this.path,
    this.handler, {
    this.public = false,
  });
  final String id;
  final String method;
  final String path;
  final Handler handler;

  /// Called by devices or through signed URLs, without an API key.
  final bool public;

  String get shelfPath =>
      '/api/v1${path.replaceAllMapped(RegExp(r'\{(\w+)\}'), (m) => '<${m[1]}>')}';
}

List<Operation> operations(Services s) {
  final account = AccountApi(s);
  final apps = AppsApi(s);
  final transfer = TransferApi(s);
  final releases = ReleasesApi(s, transfer);
  final patches = PatchesApi(s, transfer);
  final updater = UpdaterApi(s);
  final members = MembersApi(s);
  final metrics = MetricsApi(s);
  return [
    // Users and organizations.
    Operation('getCurrentUser', 'GET', '/users/me', account.getCurrentUser),
    Operation(
      'updateCurrentUser',
      'PATCH',
      '/users/me',
      account.updateCurrentUser,
    ),
    Operation(
      'getNotificationPreferences',
      'GET',
      '/users/me/notification_preferences',
      account.getNotificationPreferences,
    ),
    Operation(
      'updateNotificationPreferences',
      'PATCH',
      '/users/me/notification_preferences',
      account.updateNotificationPreferences,
    ),
    Operation(
      'getReceivedInvitations',
      'GET',
      '/invitations',
      members.getReceivedInvitations,
    ),
    Operation('getPlan', 'GET', '/plan', account.getPlan),
    Operation('getUsage', 'GET', '/usage', account.getUsage),
    Operation(
      'getOrganizationMemberships',
      'GET',
      '/organizations',
      account.getOrganizationMemberships,
    ),
    Operation(
      'createOrganization',
      'POST',
      '/organizations',
      account.createOrganization,
    ),
    Operation(
      'getOrganization',
      'GET',
      '/organizations/{organizationId}',
      account.getOrganization,
    ),
    Operation(
      'updateOrganization',
      'PATCH',
      '/organizations/{organizationId}',
      account.updateOrganization,
    ),
    Operation(
      'getOrganizationApps',
      'GET',
      '/organizations/{organizationId}/apps',
      account.getOrganizationApps,
    ),
    Operation(
      'getOrganizationUsers',
      'GET',
      '/organizations/{organizationId}/users',
      account.getOrganizationUsers,
    ),
    Operation(
      'getOrganizationInvitations',
      'GET',
      '/organizations/{organizationId}/invitations',
      members.getOrganizationInvitations,
    ),
    Operation(
      'getOrganizationPlan',
      'GET',
      '/organizations/{organizationId}/plan',
      account.getOrganizationPlan,
    ),
    Operation(
      'getOrganizationUsage',
      'GET',
      '/organizations/{organizationId}/usage',
      account.getOrganizationUsage,
    ),
    Operation(
      'getOrganizationAuditLogs',
      'GET',
      '/organizations/{organizationId}/audit-logs',
      account.getOrganizationAuditLogs,
    ),

    Operation(
      'getInvitation',
      'GET',
      '/invitations/{invitationId}',
      members.getInvitation,
    ),
    Operation(
      'acceptInvitation',
      'POST',
      '/invitations/{invitationId}/accept',
      members.acceptInvitation,
    ),
    Operation(
      'declineInvitation',
      'POST',
      '/invitations/{invitationId}/decline',
      members.declineInvitation,
    ),
    Operation(
      'createOrganizationInvitation',
      'POST',
      '/organizations/{organizationId}/invitations',
      members.createOrganizationInvitation,
    ),
    Operation(
      'revokeOrganizationInvitation',
      'DELETE',
      '/organizations/{organizationId}/invitations/{invitationId}',
      members.revokeOrganizationInvitation,
    ),
    Operation(
      'updateOrganizationUser',
      'PATCH',
      '/organizations/{organizationId}/users/{userId}',
      members.updateOrganizationUser,
    ),
    Operation(
      'deleteOrganizationUser',
      'DELETE',
      '/organizations/{organizationId}/users/{userId}',
      members.deleteOrganizationUser,
    ),

    // Metrics.
    Operation(
      'getVersionDistribution',
      'GET',
      '/apps/{appId}/metrics/version-distribution',
      metrics.getVersionDistribution,
    ),
    Operation(
      'getNewDevices',
      'GET',
      '/apps/{appId}/metrics/new-devices',
      metrics.getNewDevices,
    ),
    Operation(
      'getPatchAdoption',
      'GET',
      '/apps/{appId}/metrics/patch-adoption',
      metrics.getPatchAdoption,
    ),
    Operation(
      'getActiveHours',
      'GET',
      '/apps/{appId}/metrics/active-hours',
      metrics.getActiveHours,
    ),
    Operation(
      'getActivityHeatmap',
      'GET',
      '/apps/{appId}/metrics/activity-heatmap',
      metrics.getActivityHeatmap,
    ),
    Operation(
      'getUniqueUsers',
      'GET',
      '/apps/{appId}/metrics/unique-users',
      metrics.getUniqueUsers,
    ),
    Operation(
      'getAppPatchInstalls',
      'GET',
      '/apps/{appId}/metrics/patch-installs',
      metrics.getAppPatchInstalls,
    ),
    Operation(
      'getAppPatchDownloads',
      'GET',
      '/apps/{appId}/metrics/patch-downloads',
      metrics.getAppPatchDownloads,
    ),
    Operation(
      'getReleasePatchInstalls',
      'GET',
      '/apps/{appId}/releases/{releaseId}/metrics/patch-installs',
      metrics.getReleasePatchInstalls,
    ),
    Operation(
      'getReleasePatchDownloads',
      'GET',
      '/apps/{appId}/releases/{releaseId}/metrics/patch-downloads',
      metrics.getReleasePatchDownloads,
    ),

    // Apps and channels.
    Operation('getApps', 'GET', '/apps', apps.getApps),
    Operation('createApp', 'POST', '/apps', apps.createApp),
    Operation('getApp', 'GET', '/apps/{appId}', apps.getApp),
    Operation('updateApp', 'PATCH', '/apps/{appId}', apps.updateApp),
    Operation('deleteApp', 'DELETE', '/apps/{appId}', apps.deleteApp),
    Operation(
      'getAppSigningKey',
      'GET',
      '/apps/{appId}/signing-key',
      apps.getAppSigningKey,
    ),
    Operation(
      'getAppCollaborators',
      'GET',
      '/apps/{appId}/collaborators',
      apps.getAppCollaborators,
    ),
    Operation(
      'getAppInvitations',
      'GET',
      '/apps/{appId}/invitations',
      apps.getAppInvitations,
    ),
    Operation('getChannels', 'GET', '/apps/{appId}/channels', apps.getChannels),
    Operation(
      'createChannel',
      'POST',
      '/apps/{appId}/channels',
      apps.createChannel,
    ),
    Operation(
      'deleteChannel',
      'DELETE',
      '/apps/{appId}/channels/{channelId}',
      apps.deleteChannel,
    ),

    // Releases.
    Operation(
      'getReleases',
      'GET',
      '/apps/{appId}/releases',
      releases.getReleases,
    ),
    Operation(
      'createRelease',
      'POST',
      '/apps/{appId}/releases',
      releases.createRelease,
    ),
    Operation(
      'getRelease',
      'GET',
      '/apps/{appId}/releases/{releaseId}',
      releases.getRelease,
    ),
    Operation(
      'updateRelease',
      'PATCH',
      '/apps/{appId}/releases/{releaseId}',
      releases.updateRelease,
    ),
    Operation(
      'deleteRelease',
      'DELETE',
      '/apps/{appId}/releases/{releaseId}',
      releases.deleteRelease,
    ),
    Operation(
      'getReleaseArtifacts',
      'GET',
      '/apps/{appId}/releases/{releaseId}/artifacts',
      releases.getReleaseArtifacts,
    ),
    Operation(
      'createReleaseArtifact',
      'POST',
      '/apps/{appId}/releases/{releaseId}/artifacts',
      releases.createReleaseArtifact,
    ),
    Operation(
      'deleteReleaseArtifacts',
      'DELETE',
      '/apps/{appId}/releases/{releaseId}/artifacts',
      releases.deleteReleaseArtifacts,
    ),

    // Patches.
    Operation(
      'getReleasePatches',
      'GET',
      '/apps/{appId}/releases/{releaseId}/patches',
      patches.getReleasePatches,
    ),
    Operation(
      'updatePatch',
      'PATCH',
      '/apps/{appId}/releases/{releaseId}/patches/{patchId}',
      patches.updatePatch,
    ),
    Operation(
      'createPatch',
      'POST',
      '/apps/{appId}/patches',
      patches.createPatch,
    ),
    Operation(
      'createPatchArtifact',
      'POST',
      '/apps/{appId}/patches/{patchId}/artifacts',
      patches.createPatchArtifact,
    ),
    Operation(
      'promotePatch',
      'POST',
      '/apps/{appId}/patches/promote',
      patches.promotePatch,
    ),
    Operation(
      'setPatchRollout',
      'PUT',
      '/apps/{appId}/releases/{releaseId}/patches/{patchId}/rollout',
      patches.setPatchRollout,
    ),
    Operation(
      'rollbackPatch',
      'POST',
      '/apps/{appId}/releases/{releaseId}/patches/{patchId}/rollback',
      patches.rollbackPatch,
    ),
    Operation(
      'rollforwardPatch',
      'POST',
      '/apps/{appId}/releases/{releaseId}/patches/{patchId}/rollforward',
      patches.rollforwardPatch,
    ),
    Operation(
      'createBuildRun',
      'POST',
      '/apps/{appId}/runs',
      patches.createBuildRun,
    ),

    // Devices.
    Operation(
      'patchCheck',
      'POST',
      '/patches/check',
      updater.patchCheck,
      public: true,
    ),
    Operation(
      'createPatchEvent',
      'POST',
      '/patches/events',
      updater.createPatchEvent,
      public: true,
    ),

    // Transfers (our own URLs, not part of Shorebird's protocol).
    Operation(
      'uploadMultipart',
      'POST',
      '/uploads/{token}',
      transfer.uploadMultipart,
      public: true,
    ),
    Operation(
      'uploadResumable',
      'PUT',
      '/uploads/{token}',
      transfer.uploadResumable,
      public: true,
    ),
  ];
}

/// The whole HTTP handler: logging, errors, auth, routes.
Handler buildHandler(Services s) {
  final ops = operations(s);
  final transfer = TransferApi(s);
  final console = ConsoleApi(s);
  final router = Router(notFoundHandler: _unsupported)
    ..get('/healthz', (Request _) => Response.ok('ok'))
    ..get('/api/v1/files/<key|.*>', transfer.download)
    ..head('/api/v1/files/<key|.*>', transfer.download)
    // Console-only routes (not part of Shorebird's protocol).
    ..get('/console/v1/config', console.config)
    ..get('/console/v1/session', console.session)
    ..post('/console/v1/session', console.login)
    ..delete('/console/v1/session', console.logout)
    ..post('/console/v1/signup', console.signup)
    ..post('/console/v1/account/password', console.changePassword)
    ..get('/console/v1/api-keys', console.listApiKeys)
    ..post('/console/v1/api-keys', console.createApiKey)
    ..delete('/console/v1/api-keys/<keyId>', console.revokeApiKey)
    ..get('/console/v1/apps/<appId>/build-runs', console.buildRuns)
    ..get('/console/v1/apps/<appId>/events', console.events)
    ..get('/console/v1/apps/<appId>/summary', console.summary);
  for (final op in ops) {
    router.add(op.method, op.shelfPath, op.handler);
  }
  final publicMatchers = [
    for (final op in ops.where((o) => o.public))
      (
        op.method,
        RegExp('^${op.shelfPath.replaceAll(RegExp(r'<\w+>'), '[^/]+')}\$'),
      ),
  ];
  bool isApi(String path) =>
      path.startsWith('/api/') || path.startsWith('/console/');
  bool isPublic(Request request) {
    final path = '/${request.url.path}';
    if (!isApi(path)) return true; // console assets and /healthz
    if (path.startsWith('/api/v1/files/') || path == '/console/v1/config') {
      return true;
    }
    return publicMatchers.any(
      (m) => m.$1 == request.method && m.$2.hasMatch(path),
    );
  }

  bool isOptional(Request request) {
    final path = '/${request.url.path}';
    return path == '/console/v1/session' || path == '/console/v1/signup';
  }

  final dashboard = s.config.dashboardDir;
  final assets = dashboard == null
      ? null
      : createStaticHandler(dashboard, defaultDocument: 'index.html');
  Future<Response> app(Request request) async {
    final path = '/${request.url.path}';
    if (assets == null || isApi(path) || path == '/healthz') {
      return router.call(request);
    }
    final response = await assets(request);
    if (response.statusCode != 404) return response;
    // Client-side routes get the app shell.
    return Response.ok(
      File('$dashboard/index.html').openRead(),
      headers: {
        'content-type': 'text/html; charset=utf-8',
        'cache-control': 'no-cache',
      },
    );
  }

  return const Pipeline()
      .addMiddleware(_logRequests)
      .addMiddleware(_handleErrors)
      .addMiddleware(
        authMiddleware(
          s.apiKeys,
          s.sessions,
          isPublic: isPublic,
          isOptional: isOptional,
        ),
      )
      .addHandler(app);
}

Response _unsupported(Request request) {
  final path = '/${request.url.path}';
  if (!path.startsWith('/api/v1/')) {
    return ApiError.notFound('Route').toResponse();
  }
  return ApiError(
    501,
    'unsupported_operation',
    'This self-hosted server does not implement ${request.method} $path.',
  ).toResponse();
}

Handler _handleErrors(Handler inner) => (request) async {
  try {
    return await inner(request);
  } on ApiError catch (error) {
    return error.toResponse();
  } catch (error, stack) {
    _log.severe('${request.method} ${request.url}', error, stack);
    return ApiError(
      500,
      'internal_error',
      'Internal server error.',
    ).toResponse();
  }
};

Handler _logRequests(Handler inner) => (request) async {
  final watch = Stopwatch()..start();
  final response = await inner(request);
  _log.info(
    '${request.method} /${request.url.path} ${response.statusCode} ${watch.elapsedMilliseconds}ms',
  );
  return response;
};
