import 'dart:async';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shorebird_code_push_protocol/shorebird_code_push_protocol.dart';

import '../http.dart';
import '../patch_selection.dart';
import '../services.dart';

final _log = Logger('updater');

/// The two routes devices call, unauthenticated, from the Shorebird updater
/// built into every release (`updater/library/src/network.rs`).
///
/// Every updater version still in the field must keep working, so these
/// only ever gain optional fields. See docs/PROTOCOL.md.
class UpdaterApi {
  UpdaterApi(this.s);
  final Services s;

  static const _noPatch = PatchCheckResponse(patchAvailable: false);

  Future<Response> patchCheck(Request request) async {
    final body = parseBody(
      await readJsonObject(request),
      PatchCheckRequest.fromJson,
    );
    unawaited(_recordActivity(body));
    final release = await s.db.one(
      'SELECT r.id FROM releases r WHERE r.app_id = @a AND r.version = @v',
      {'a': body.appId, 'v': body.releaseVersion},
    );
    if (release == null) return jsonResponse(_noPatch.toJson());
    final releaseId = release['id'] as int;

    final rows = await s.db.query(
      'SELECT p.id, p.number, p.rollout_percentage, p.is_rolled_back, '
      ' pa.hash, pa.hash_signature, pa.storage_key '
      'FROM patches p '
      'JOIN channels c ON c.id = p.channel_id '
      'JOIN patch_artifacts pa ON pa.patch_id = p.id '
      'WHERE p.release_id = @r AND c.name = @channel '
      ' AND pa.platform = @platform AND pa.arch = @arch AND pa.uploaded_at IS NOT NULL '
      'ORDER BY p.number DESC',
      {
        'r': releaseId,
        'channel': body.channel,
        'platform': body.platform.value,
        'arch': body.arch,
      },
    );
    final byId = {for (final row in rows) row['id'] as int: row};
    final selected = selectPatch(
      [
        for (final row in rows)
          PatchCandidate(
            id: row['id'] as int,
            number: row['number'] as int,
            rolloutPercentage: (row['rollout_percentage'] as num?)?.toDouble(),
            isRolledBack: row['is_rolled_back'] as bool,
          ),
      ],
      clientId: body.clientId,
      legacyPatchNumber: body.patchNumber,
    );

    // Devices running a rolled-back patch revert, whichever channel it was on.
    final rolledBack = [
      for (final row in await s.db.query(
        'SELECT number FROM patches WHERE release_id = @r AND is_rolled_back ORDER BY number',
        {'r': releaseId},
      ))
        row['number'] as int,
    ];

    if (selected == null) {
      return jsonResponse(
        PatchCheckResponse(
          patchAvailable: false,
          rolledBackPatchNumbers: rolledBack.isEmpty ? null : rolledBack,
        ).toJson(),
      );
    }
    final row = byId[selected.id]!;
    return jsonResponse(
      PatchCheckResponse(
        patchAvailable: true,
        patch: PatchCheckMetadata(
          number: selected.number,
          hash: row['hash'] as String,
          hashSignature: row['hash_signature'] as String?,
          downloadUrl: await s.downloadUrl(
            request,
            row['storage_key'] as String,
          ),
        ),
        rolledBackPatchNumbers: rolledBack.isEmpty ? null : rolledBack,
      ).toJson(),
    );
  }

  /// Records the install's activity for the metrics endpoints: the device
  /// row (current release and patch) and one row per install per hour.
  /// Off the request path; a failure only loses a data point.
  Future<void> _recordActivity(PatchCheckRequest body) async {
    final clientId = body.clientId;
    if (clientId == null || clientId.isEmpty) return;
    final params = {
      'app': body.appId,
      'cid': clientId,
      'rv': body.releaseVersion,
      'platform': body.platform.value,
      'arch': body.arch,
      'pn': body.currentPatchNumber,
    };
    try {
      await s.db.execute(
        'INSERT INTO devices (app_id, client_id, release_version, platform, arch, patch_number) '
        'VALUES (@app, @cid, @rv, @platform, @arch, @pn) '
        'ON CONFLICT (app_id, client_id) DO UPDATE SET last_seen = now(), '
        ' release_version = EXCLUDED.release_version, platform = EXCLUDED.platform, '
        ' arch = EXCLUDED.arch, patch_number = EXCLUDED.patch_number',
        params,
      );
      await s.db.execute(
        'INSERT INTO device_activity (app_id, client_id, hour, release_version, platform, patch_number) '
        "VALUES (@app, @cid, date_trunc('hour', now()), @rv, @platform, @pn) "
        'ON CONFLICT (app_id, hour, client_id) DO UPDATE SET '
        ' release_version = EXCLUDED.release_version, patch_number = EXCLUDED.patch_number',
        {...params}..remove('arch'),
      );
    } on Object catch (error) {
      _log.warning('Could not record device activity: $error');
    }
  }

  /// `POST /api/v1/patches/events`, body `{"event": PatchEvent}`
  /// (updater `events.rs`). Not in openapi.yaml. Retries are deduplicated
  /// by `event_id`. Malformed events are dropped rather than refused, so a
  /// device never retries them forever.
  Future<Response> createPatchEvent(Request request) async {
    final json = await readJsonObject(request);
    final event = json['event'];
    if (event is! Map<String, dynamic>) {
      throw ApiError.badRequest('Missing "event".');
    }
    String? str(String k) => event[k] is String ? event[k] as String : null;
    final type = str('type');
    final appId = str('app_id');
    final patchNumber = event['patch_number'];
    final timestamp = event['timestamp'];
    if (type == null ||
        appId == null ||
        patchNumber is! int ||
        timestamp is! int) {
      return Response(204);
    }
    await s.db.execute(
      'INSERT INTO patch_events (event_id, app_id, release_version, patch_number, platform, arch, client_id, '
      ' type, message, failure_category, occurred_at) '
      'VALUES (@eid, @app, @rv, @pn, @platform, @arch, @cid, @type, @msg, @fc, to_timestamp(@ts)) '
      'ON CONFLICT (event_id) DO NOTHING',
      {
        'eid': str('event_id'),
        'app': appId,
        'rv': str('release_version') ?? '',
        'pn': patchNumber,
        'platform': str('platform') ?? '',
        'arch': str('arch') ?? '',
        'cid': str('client_id') ?? '',
        'type': type,
        'msg': str('message'),
        'fc': str('failure_category'),
        'ts': timestamp.toDouble(),
      },
    );
    return Response(201);
  }
}
