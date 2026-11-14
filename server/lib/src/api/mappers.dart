import 'package:shorebird_code_push_protocol/shorebird_code_push_protocol.dart';

import '../db.dart';

/// Row → protocol model conversions. Everything the server answers is built
/// from the pinned protocol package, so the JSON matches what the CLI parses.

DateTime _ts(Object? v) => (v as DateTime).toUtc();

Organization organizationFrom(Map<String, dynamic> row) => Organization(
  id: row['id'] as int,
  name: row['name'] as String,
  organizationType: OrganizationType.fromJson(
    row['organization_type'] as String,
  ),
  createdAt: _ts(row['created_at']),
  updatedAt: _ts(row['updated_at']),
);

Role roleFrom(Object? value) =>
    Role.values.firstWhere((r) => r.value == value, orElse: () => Role.none);

Channel channelFrom(Map<String, dynamic> row) => Channel(
  id: row['id'] as int,
  appId: row['app_id'] as String,
  name: row['name'] as String,
);

/// Loads [AppMetadata] for [appIds], with the latest release and patch
/// summaries the CLI's `apps list` shows.
Future<List<AppMetadata>> loadAppMetadata(Db db, List<String> appIds) async {
  if (appIds.isEmpty) return [];
  final rows = await db.query(
    'SELECT a.*, '
    ' (SELECT r.version FROM releases r WHERE r.app_id = a.id ORDER BY r.created_at DESC, r.id DESC LIMIT 1) AS latest_release_version, '
    ' (SELECT max(p.number) FROM patches p JOIN releases r ON r.id = p.release_id '
    '   WHERE r.id = (SELECT r2.id FROM releases r2 WHERE r2.app_id = a.id ORDER BY r2.created_at DESC, r2.id DESC LIMIT 1)) AS latest_patch_number, '
    ' ARRAY(SELECT DISTINCT rp.platform FROM release_platforms rp JOIN releases r ON r.id = rp.release_id WHERE r.app_id = a.id) AS platforms '
    'FROM apps a WHERE a.id = ANY(@ids) ORDER BY a.created_at',
    {'ids': appIds},
  );
  return [
    for (final row in rows)
      AppMetadata(
        appId: row['id'] as String,
        organizationId: row['organization_id'] as int,
        displayName: row['display_name'] as String,
        createdAt: _ts(row['created_at']),
        updatedAt: _ts(row['updated_at']),
        patchSigningRequired: false,
        latestReleaseVersion: row['latest_release_version'] as String?,
        latestPatchNumber: row['latest_patch_number'] as int?,
        platforms: [
          for (final p in (row['platforms'] as List?) ?? const [])
            ReleasePlatform.fromJson(p as String),
        ],
      ),
  ];
}

/// Loads [Release]s, with each platform's status and signing mode.
Future<List<Release>> loadReleases(
  Db db, {
  required String appId,
  int? releaseId,
  bool sideloadableOnly = false,
}) async {
  final rows = await db.query(
    'SELECT r.*, '
    " COALESCE((SELECT jsonb_object_agg(rp.platform, jsonb_build_object('status', rp.status, 'signing_mode', rp.signing_mode)) "
    '   FROM release_platforms rp WHERE rp.release_id = r.id), \'{}\'::jsonb) AS platforms '
    'FROM releases r WHERE r.app_id = @app '
    '${releaseId != null ? 'AND r.id = @id ' : ''}'
    '${sideloadableOnly ? 'AND EXISTS (SELECT 1 FROM release_artifacts ra WHERE ra.release_id = r.id AND ra.can_sideload) ' : ''}'
    'ORDER BY r.created_at, r.id',
    {'app': appId, 'id': ?releaseId},
  );
  return [
    for (final row in rows)
      () {
        final platforms = <ReleasePlatform, ReleasePlatformDetails>{
          for (final MapEntry(:key, :value)
              in (row['platforms'] as Map<String, dynamic>).entries)
            ReleasePlatform.fromJson(key): ReleasePlatformDetails(
              status: ReleaseStatus.fromJson(
                (value as Map)['status'] as String,
              ),
              signingMode: value['signing_mode'] as String?,
            ),
        };
        return Release(
          id: row['id'] as int,
          appId: row['app_id'] as String,
          version: row['version'] as String,
          flutterRevision: row['flutter_revision'] as String,
          flutterVersion: row['flutter_version'] as String?,
          displayName: row['display_name'] as String?,
          notes: row['notes'] as String?,
          platforms: platforms,
          // Still read by older CLIs.
          // ignore: deprecated_member_use
          platformStatuses: {
            for (final e in platforms.entries) e.key: e.value.status,
          },
          createdAt: _ts(row['created_at']),
          updatedAt: _ts(row['updated_at']),
        );
      }(),
  ];
}

/// Loads a release's patches with their artifacts and channel.
Future<List<ReleasePatch>> loadReleasePatches(Db db, int releaseId) async {
  final patches = await db.query(
    'SELECT p.*, c.name AS channel_name FROM patches p '
    'LEFT JOIN channels c ON c.id = p.channel_id '
    'WHERE p.release_id = @r ORDER BY p.number',
    {'r': releaseId},
  );
  final artifacts = await db.query(
    'SELECT pa.* FROM patch_artifacts pa JOIN patches p ON p.id = pa.patch_id '
    'WHERE p.release_id = @r AND pa.uploaded_at IS NOT NULL ORDER BY pa.id',
    {'r': releaseId},
  );
  return [
    for (final p in patches)
      ReleasePatch(
        id: p['id'] as int,
        number: p['number'] as int,
        channel: p['channel_name'] as String?,
        isRolledBack: p['is_rolled_back'] as bool,
        createdAt: _ts(p['created_at']),
        rolloutPercentage: p['channel_name'] == null
            ? null
            : (p['rollout_percentage'] as num?)?.toDouble() ?? 100,
        notes: p['notes'] as String?,
        artifacts: [
          for (final a in artifacts.where((a) => a['patch_id'] == p['id']))
            PatchArtifact(
              id: a['id'] as int,
              patchId: a['patch_id'] as int,
              arch: a['arch'] as String,
              platform: ReleasePlatform.fromJson(a['platform'] as String),
              hash: a['hash'] as String,
              size: a['size'] as int,
              createdAt: _ts(a['created_at']),
            ),
        ],
      ),
  ];
}
