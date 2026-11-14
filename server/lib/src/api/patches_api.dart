import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shorebird_code_push_protocol/shorebird_code_push_protocol.dart';

import '../auth.dart';
import '../db.dart';
import '../forms.dart';
import '../http.dart';
import '../services.dart';
import 'mappers.dart';
import 'transfer_api.dart';

/// Patches: creation, artifacts, channel promotion, rollout and rollback.
///
/// `shorebird patch` creates the patch, uploads one artifact per arch, then
/// promotes it to the track's channel (creating the channel if needed).
class PatchesApi {
  PatchesApi(this.s, this.transfer);
  final Services s;
  final TransferApi transfer;

  Future<Response> getReleasePatches(Request request) async {
    final appId = pathString(request, 'appId');
    await s.access.requireApp(request.principal, appId);
    final releaseId = pathInt(request, 'releaseId');
    await s.access.requireRelease(appId, releaseId);
    return jsonResponse(
      GetReleasePatchesResponse(
        patches: await loadReleasePatches(s.db, releaseId),
      ).toJson(),
    );
  }

  Future<Response> createPatch(Request request) async {
    final appId = pathString(request, 'appId');
    await s.access.requireApp(request.principal, appId, anyOf: writeRoles);
    final body = parseBody(
      await readJsonObject(request),
      CreatePatchRequest.fromJson,
    );
    await s.access.requireRelease(appId, body.releaseId);
    final row = await s.db.tx((tx) async {
      // Serialise numbering per release.
      await tx.execute(
        r'SELECT id FROM releases WHERE id = $1 FOR UPDATE',
        parameters: [body.releaseId],
      );
      return (await queryIn(
        tx,
        'INSERT INTO patches (release_id, number, metadata) '
        'VALUES (@r, (SELECT COALESCE(max(number), 0) + 1 FROM patches WHERE release_id = @r), CAST(@m AS jsonb)) '
        'RETURNING id, number',
        {'r': body.releaseId, 'm': jsonEncode(body.metadata)},
      )).single;
    });
    return jsonResponse(
      CreatePatchResponse(
        id: row['id'] as int,
        number: row['number'] as int,
      ).toJson(),
      status: 201,
    );
  }

  Future<Response> updatePatch(Request request) async {
    final appId = pathString(request, 'appId');
    await s.access.requireApp(request.principal, appId, anyOf: writeRoles);
    final patch = await s.access.requirePatch(
      appId,
      pathInt(request, 'patchId'),
    );
    if (patch['release_id'] != pathInt(request, 'releaseId')) {
      throw ApiError.notFound('Patch');
    }
    final body = parseBody(
      await readJsonObject(request),
      UpdatePatchRequest.fromJson,
    );
    await s.db.execute(
      'UPDATE patches SET notes = @n, updated_at = now() WHERE id = @id',
      {'n': body.notes, 'id': patch['id']},
    );
    return noContent();
  }

  Future<Response> createPatchArtifact(Request request) async {
    final appId = pathString(request, 'appId');
    await s.access.requireApp(request.principal, appId, anyOf: writeRoles);
    final patch = await s.access.requirePatch(
      appId,
      pathInt(request, 'patchId'),
    );
    final body = parseBody(
      await readFormOrJson(request, intFields: {'size'}),
      CreatePatchArtifactRequest.fromJson,
    );
    final platform = body.platform.value;
    final releaseId = patch['release_id'] as int;

    // Managed signing: Shorebird signs patches to a release that embeds a
    // managed key, with that key. Prefer the matching arch's artifact; all
    // of a platform's artifacts embed the same key.
    var signature = body.hashSignature;
    final managed = await s.db.one(
      'SELECT signing_key_id FROM release_artifacts '
      "WHERE release_id = @r AND platform = @p AND signing_mode = 'managed' AND signing_key_id IS NOT NULL "
      'ORDER BY (arch = @a) DESC, id LIMIT 1',
      {'r': releaseId, 'p': platform, 'a': body.arch},
    );
    if (managed != null) {
      if (signature != null) {
        throw ApiError.badRequest(
          'This release embeds a managed signing key; the server signs its patches.',
        );
      }
      signature = await s.signingKeys.sign(
        managed['signing_key_id'] as int,
        body.hash,
      );
    }

    final storageKey =
        'apps/$appId/releases/$releaseId/patches/${patch['number']}/$platform/${body.arch}/patch.bin';
    final row = await s.db.one(
      'INSERT INTO patch_artifacts (patch_id, platform, arch, hash, hash_signature, podfile_lock_hash, size, storage_key) '
      'VALUES (@pid, @p, @a, @h, @sig, @plh, @size, @key) '
      'ON CONFLICT (patch_id, platform, arch) DO NOTHING RETURNING id',
      {
        'pid': patch['id'],
        'p': platform,
        'a': body.arch,
        'h': body.hash,
        'sig': signature,
        'plh': body.podfileLockHash,
        'size': body.size,
        'key': storageKey,
      },
    );
    if (row == null) {
      throw ApiError.conflict(
        'The ${body.arch} artifact for this patch already exists.',
      );
    }
    final artifactId = row['id'] as int;
    // No expected hash: a patch's `hash` is of the patched snapshot the
    // device ends up with, not of the uploaded diff.
    final url = await transfer.createUploadSession(
      request,
      target: UploadTarget.patchArtifact,
      targetId: artifactId,
      storageKey: storageKey,
      expectedSize: body.size,
    );
    return jsonResponse(
      CreatePatchArtifactResponse(
        id: artifactId,
        patchId: patch['id'] as int,
        arch: body.arch,
        platform: body.platform,
        hash: body.hash,
        size: body.size,
        url: url,
        uploadMethod: ArtifactUploadMethod.resumable,
      ).toJson(),
    );
  }

  Future<Response> promotePatch(Request request) async {
    final appId = pathString(request, 'appId');
    await s.access.requireApp(request.principal, appId, anyOf: writeRoles);
    final body = parseBody(
      await readJsonObject(request),
      PromotePatchRequest.fromJson,
    );
    final patch = await s.access.requirePatch(appId, body.patchId);
    final channel = await s.db.one(
      'SELECT id FROM channels WHERE id = @id AND app_id = @a',
      {'id': body.channelId, 'a': appId},
    );
    if (channel == null) throw ApiError.notFound('Channel');
    final pct = _validPercentage(body.rolloutPercentage ?? 100);
    final missing = await s.db.one(
      'SELECT count(*) AS n FROM patch_artifacts WHERE patch_id = @id AND uploaded_at IS NULL',
      {'id': patch['id']},
    );
    if ((missing!['n'] as int) > 0) {
      throw ApiError.conflict(
        'The patch has artifacts that have not finished uploading.',
      );
    }
    await s.db.execute(
      'UPDATE patches SET channel_id = @c, rollout_percentage = @pct, updated_at = now() WHERE id = @id',
      {'c': body.channelId, 'pct': pct, 'id': patch['id']},
    );
    return noContent();
  }

  /// PUT …/rollout (client route, not in openapi.yaml): rollouts only go up.
  Future<Response> setPatchRollout(Request request) async {
    final appId = pathString(request, 'appId');
    await s.access.requireApp(request.principal, appId, anyOf: writeRoles);
    final patch = await _patchOfRelease(request, appId);
    final body = parseBody(
      await readJsonObject(request),
      SetPatchRolloutRequest.fromJson,
    );
    final pct = _validPercentage(body.rolloutPercentage);
    if (patch['channel_id'] == null) {
      throw ApiError.conflict('The patch is on no channel; promote it first.');
    }
    final current = (patch['rollout_percentage'] as num?)?.toDouble() ?? 100;
    if (pct < current) {
      throw ApiError.conflict(
        'Rollouts only go up: the patch is at $current%.',
      );
    }
    await s.db.execute(
      'UPDATE patches SET rollout_percentage = @pct, updated_at = now() WHERE id = @id',
      {'pct': pct, 'id': patch['id']},
    );
    return noContent();
  }

  Future<Response> rollbackPatch(Request request) =>
      _setRolledBack(request, true);

  Future<Response> rollforwardPatch(Request request) =>
      _setRolledBack(request, false);

  /// 204 when changed, 304 when the patch was already in that state.
  Future<Response> _setRolledBack(Request request, bool rolledBack) async {
    final appId = pathString(request, 'appId');
    await s.access.requireApp(request.principal, appId, anyOf: writeRoles);
    final patch = await _patchOfRelease(request, appId);
    final changed = await s.db.execute(
      'UPDATE patches SET is_rolled_back = @v, updated_at = now() WHERE id = @id AND is_rolled_back <> @v',
      {'v': rolledBack, 'id': patch['id']},
    );
    return Response(changed == 0 ? 304 : 204);
  }

  Future<Map<String, dynamic>> _patchOfRelease(
    Request request,
    String appId,
  ) async {
    final patch = await s.access.requirePatch(
      appId,
      pathInt(request, 'patchId'),
    );
    if (patch['release_id'] != pathInt(request, 'releaseId')) {
      throw ApiError.notFound('Patch');
    }
    return patch;
  }

  double _validPercentage(double pct) {
    final hundredths = pct * 100;
    if (pct < 0.01 ||
        pct > 100 ||
        (hundredths - hundredths.round()).abs() > 1e-6) {
      throw ApiError.badRequest(
        'rollout_percentage must be a multiple of 0.01 from 0.01 to 100.',
      );
    }
    return hundredths.round() / 100;
  }

  /// Build history: recorded for the operator; nothing to upload.
  Future<Response> createBuildRun(Request request) async {
    final appId = pathString(request, 'appId');
    await s.access.requireApp(request.principal, appId, anyOf: writeRoles);
    final json = await readJsonObject(request);
    final body = parseBody(json, CreateBuildRunRequest.fromJson);
    final row = await s.db.one(
      'INSERT INTO build_runs (app_id, run_id, command, platform, outcome, payload) '
      'VALUES (@a, @run, @cmd, @p, @o, CAST(@payload AS jsonb)) RETURNING id',
      {
        'a': appId,
        'run': body.runId,
        'cmd': body.command.value,
        'p': body.platform.value,
        'o': body.outcome.value,
        'payload': jsonEncode(json),
      },
    );
    return jsonResponse(
      CreateBuildRunResponse(id: row!['id'] as int).toJson(),
      status: 201,
    );
  }
}
