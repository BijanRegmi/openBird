import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shorebird_code_push_protocol/shorebird_code_push_protocol.dart';

import '../auth.dart';
import '../forms.dart';
import '../http.dart';
import '../services.dart';
import 'mappers.dart';
import 'transfer_api.dart';

/// Releases and their artifacts.
///
/// `shorebird release` lists releases, creates the release when the version
/// is new, marks the platform `draft`, uploads each artifact, then marks the
/// platform `active` with build metadata.
class ReleasesApi {
  ReleasesApi(this.s, this.transfer);
  final Services s;
  final TransferApi transfer;

  Future<Response> getReleases(Request request) async {
    final appId = pathString(request, 'appId');
    await s.access.requireApp(request.principal, appId);
    final releases = await loadReleases(
      s.db,
      appId: appId,
      sideloadableOnly: request.url.queryParameters['sideloadable'] == 'true',
    );
    return jsonResponse(GetReleasesResponse(releases: releases).toJson());
  }

  Future<Response> getRelease(Request request) async {
    final appId = pathString(request, 'appId');
    await s.access.requireApp(request.principal, appId);
    final releases = await loadReleases(
      s.db,
      appId: appId,
      releaseId: pathInt(request, 'releaseId'),
    );
    if (releases.isEmpty) throw ApiError.notFound('Release');
    return jsonResponse(GetReleaseResponse(release: releases.single).toJson());
  }

  Future<Response> createRelease(Request request) async {
    final appId = pathString(request, 'appId');
    await s.access.requireApp(request.principal, appId, anyOf: writeRoles);
    final body = parseBody(
      await readJsonObject(request),
      CreateReleaseRequest.fromJson,
    );
    final row = await s.db.one(
      'INSERT INTO releases (app_id, version, flutter_revision, flutter_version, display_name) '
      'VALUES (@a, @v, @rev, @fv, @dn) ON CONFLICT (app_id, version) DO NOTHING RETURNING id',
      {
        'a': appId,
        'v': body.version,
        'rev': body.flutterRevision,
        'fv': body.flutterVersion,
        'dn': body.displayName,
      },
    );
    if (row == null) {
      throw ApiError.conflict(
        'Release ${body.version} already exists.',
        code: 'release_exists',
      );
    }
    final release = (await loadReleases(
      s.db,
      appId: appId,
      releaseId: row['id'] as int,
    )).single;
    return jsonResponse(CreateReleaseResponse(release: release).toJson());
  }

  Future<Response> updateRelease(Request request) async {
    final appId = pathString(request, 'appId');
    await s.access.requireApp(request.principal, appId, anyOf: writeRoles);
    final releaseId = pathInt(request, 'releaseId');
    await s.access.requireRelease(appId, releaseId);
    final body = parseBody(
      await readJsonObject(request),
      UpdateReleaseRequest.fromJson,
    );
    if (body.status != null && body.platform == null) {
      throw ApiError.badRequest('platform is required with status.');
    }
    await s.db.tx((tx) async {
      if (body.status != null) {
        await tx.execute(
          r'INSERT INTO release_platforms (release_id, platform, status, metadata) '
          r'VALUES ($1, $2, $3, CAST($4 AS jsonb)) '
          r'ON CONFLICT (release_id, platform) DO UPDATE SET status = EXCLUDED.status, '
          r'metadata = COALESCE(EXCLUDED.metadata, release_platforms.metadata), updated_at = now()',
          parameters: [
            releaseId,
            body.platform!.value,
            body.status!.value,
            body.metadata == null ? null : jsonEncode(body.metadata),
          ],
        );
      }
      if (body.notes != null) {
        await tx.execute(
          r'UPDATE releases SET notes = $1 WHERE id = $2',
          parameters: [body.notes, releaseId],
        );
      }
      await tx.execute(
        r'UPDATE releases SET updated_at = now() WHERE id = $1',
        parameters: [releaseId],
      );
    });
    return noContent();
  }

  Future<Response> deleteRelease(Request request) async {
    final appId = pathString(request, 'appId');
    await s.access.requireApp(request.principal, appId, anyOf: writeRoles);
    final releaseId = pathInt(request, 'releaseId');
    await s.access.requireRelease(appId, releaseId);
    await s.db.execute('DELETE FROM releases WHERE id = @id', {
      'id': releaseId,
    });
    await s.storage.deletePrefix('apps/$appId/releases/$releaseId/');
    return noContent();
  }

  Future<Response> getReleaseArtifacts(Request request) async {
    final appId = pathString(request, 'appId');
    await s.access.requireApp(request.principal, appId);
    final releaseId = pathInt(request, 'releaseId');
    await s.access.requireRelease(appId, releaseId);
    final q = request.url.queryParameters;
    final rows = await s.db.query(
      'SELECT ra.*, sk.public_key_pem FROM release_artifacts ra '
      'LEFT JOIN signing_keys sk ON sk.id = ra.signing_key_id '
      'WHERE ra.release_id = @r AND ra.uploaded_at IS NOT NULL '
      '${q['arch'] != null ? 'AND ra.arch = @arch ' : ''}'
      '${q['platform'] != null ? 'AND ra.platform = @platform ' : ''}'
      'ORDER BY ra.id',
      {'r': releaseId, 'arch': ?q['arch'], 'platform': ?q['platform']},
    );
    final artifacts = [
      for (final row in rows)
        ReleaseArtifact(
          id: row['id'] as int,
          releaseId: releaseId,
          arch: row['arch'] as String,
          platform: ReleasePlatform.fromJson(row['platform'] as String),
          hash: row['hash'] as String,
          size: row['size'] as int,
          url: await s.downloadUrl(request, row['storage_key'] as String),
          canSideload: row['can_sideload'] as bool,
          podfileLockHash: row['podfile_lock_hash'] as String?,
          signing: row['signing_mode'] == null
              ? null
              : ArtifactSigning(
                  mode: row['signing_mode'] as String,
                  keyId: row['signing_key_id'] as int?,
                  publicKeyPem: row['public_key_pem'] as String?,
                ),
        ),
    ];
    return jsonResponse(
      GetReleaseArtifactsResponse(
        artifacts: artifacts,
        totalCount: artifacts.length,
      ).toJson(),
    );
  }

  Future<Response> createReleaseArtifact(Request request) async {
    final appId = pathString(request, 'appId');
    final app = await s.access.requireApp(
      request.principal,
      appId,
      anyOf: writeRoles,
    );
    final releaseId = pathInt(request, 'releaseId');
    await s.access.requireRelease(appId, releaseId);
    final body = parseBody(
      await readFormOrJson(
        request,
        intFields: {'size'},
        boolFields: {'can_sideload'},
        jsonFields: {'signing'},
      ),
      CreateReleaseArtifactRequest.fromJson,
    );
    final platform = body.platform.value;
    final signing = body.signing;
    if (signing?.mode == ReleaseSigningMode.managed) {
      // The key must be this organization's: a release can only embed a key
      // whose private half this server holds for the app.
      final key = signing!.keyId == null
          ? null
          : await s.db.one(
              'SELECT id FROM signing_keys WHERE id = @id AND organization_id = @o',
              {'id': signing.keyId, 'o': app['organization_id']},
            );
      if (key == null) {
        throw ApiError.badRequest('Unknown managed signing key.');
      }
    }

    final status = await s.db.one(
      'SELECT status FROM release_platforms WHERE release_id = @r AND platform = @p',
      {'r': releaseId, 'p': platform},
    );
    final existing = await s.db.one(
      'SELECT id FROM release_artifacts WHERE release_id = @r AND platform = @p AND arch = @a',
      {'r': releaseId, 'p': platform, 'a': body.arch},
    );
    // A retried `shorebird release` uploads over a draft's artifacts; an
    // active release's artifacts are final (the CLI treats 409 as "exists").
    if (existing != null && status?['status'] == 'active') {
      throw ApiError.conflict(
        'The ${body.arch} artifact for $platform already exists.',
      );
    }
    final storageKey =
        'apps/$appId/releases/$releaseId/$platform/${body.arch}/${_safeName(body.filename)}';
    final row = await s.db.one(
      'INSERT INTO release_artifacts (release_id, platform, arch, hash, size, filename, can_sideload, '
      ' podfile_lock_hash, signing_mode, signing_key_id, storage_key) '
      'VALUES (@r, @p, @a, @h, @size, @fn, @cs, @plh, @sm, @sk, @key) '
      'ON CONFLICT (release_id, platform, arch) DO UPDATE SET hash = EXCLUDED.hash, size = EXCLUDED.size, '
      ' filename = EXCLUDED.filename, can_sideload = EXCLUDED.can_sideload, '
      ' podfile_lock_hash = EXCLUDED.podfile_lock_hash, signing_mode = EXCLUDED.signing_mode, '
      ' signing_key_id = EXCLUDED.signing_key_id, storage_key = EXCLUDED.storage_key, uploaded_at = NULL '
      'RETURNING id',
      {
        'r': releaseId,
        'p': platform,
        'a': body.arch,
        'h': body.hash,
        'size': body.size,
        'fn': body.filename,
        'cs': body.canSideload ?? false,
        'plh': body.podfileLockHash,
        'sm': signing?.mode.value,
        'sk': signing?.keyId,
        'key': storageKey,
      },
    );
    if (signing != null) {
      await s.db.execute(
        "INSERT INTO release_platforms (release_id, platform, status, signing_mode) VALUES (@r, @p, 'draft', @m) "
        'ON CONFLICT (release_id, platform) DO UPDATE SET signing_mode = EXCLUDED.signing_mode',
        {'r': releaseId, 'p': platform, 'm': signing.mode.value},
      );
    }
    final artifactId = row!['id'] as int;
    final url = await transfer.createUploadSession(
      request,
      target: UploadTarget.releaseArtifact,
      targetId: artifactId,
      storageKey: storageKey,
      expectedSize: body.size,
      expectedHash: body.hash,
    );
    return jsonResponse(
      CreateReleaseArtifactResponse(
        id: artifactId,
        releaseId: releaseId,
        arch: body.arch,
        platform: body.platform,
        hash: body.hash,
        size: body.size,
        url: url,
        uploadMethod: ArtifactUploadMethod.resumable,
      ).toJson(),
    );
  }

  Future<Response> deleteReleaseArtifacts(Request request) async {
    final appId = pathString(request, 'appId');
    await s.access.requireApp(request.principal, appId, anyOf: writeRoles);
    final releaseId = pathInt(request, 'releaseId');
    await s.access.requireRelease(appId, releaseId);
    final platform = request.url.queryParameters['platform'];
    await s.db.tx((tx) async {
      final where = platform == null ? '' : r' AND platform = $2';
      final params = [releaseId, ?platform];
      await tx.execute(
        'DELETE FROM release_artifacts WHERE release_id = \$1$where',
        parameters: params,
      );
      await tx.execute(
        'DELETE FROM release_platforms WHERE release_id = \$1$where',
        parameters: params,
      );
    });
    await s.storage.deletePrefix(
      platform == null
          ? 'apps/$appId/releases/$releaseId/'
          : 'apps/$appId/releases/$releaseId/$platform/',
    );
    return noContent();
  }
}

String _safeName(String name) {
  final cleaned = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  return cleaned.isEmpty || cleaned.startsWith('.')
      ? 'artifact$cleaned'
      : cleaned;
}
