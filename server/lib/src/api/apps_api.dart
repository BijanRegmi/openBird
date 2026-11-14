import 'package:shelf/shelf.dart';
import 'package:shorebird_code_push_protocol/shorebird_code_push_protocol.dart';

import '../auth.dart';
import '../crypto.dart';
import '../http.dart';
import '../services.dart';
import 'mappers.dart';

/// Apps, channels and the managed signing key.
class AppsApi {
  AppsApi(this.s);
  final Services s;

  Future<Response> getApps(Request request) async {
    final ids = [
      for (final row in await s.db.query(
        'SELECT a.id FROM apps a JOIN organization_members m ON m.organization_id = a.organization_id '
        'WHERE m.user_id = @u',
        {'u': request.principal.userId},
      ))
        row['id'] as String,
    ];
    return jsonResponse(
      GetAppsResponse(apps: await loadAppMetadata(s.db, ids)).toJson(),
    );
  }

  Future<Response> createApp(Request request) async {
    final body = parseBody(
      await readJsonObject(request),
      CreateAppRequest.fromJson,
    );
    final name = body.displayName.trim();
    if (name.isEmpty) throw ApiError.badRequest('App name is required.');
    await s.access.requireOrgRole(
      request.principal,
      body.organizationId,
      anyOf: writeRoles,
    );
    final id = uuidV4();
    await s.db.tx((tx) async {
      await tx.execute(
        r'INSERT INTO apps (id, organization_id, display_name) VALUES ($1, $2, $3)',
        parameters: [id, body.organizationId, name],
      );
      // Devices check the stable channel unless shorebird.yaml names another.
      await tx.execute(
        r"INSERT INTO channels (app_id, name) VALUES ($1, 'stable')",
        parameters: [id],
      );
    });
    return jsonResponse(App(id: id, displayName: name).toJson());
  }

  Future<Response> getApp(Request request) async {
    final app = await s.access.requireApp(
      request.principal,
      pathString(request, 'appId'),
    );
    return jsonResponse(
      (await loadAppMetadata(s.db, [app['id'] as String])).single.toJson(),
    );
  }

  Future<Response> updateApp(Request request) async {
    final appId = pathString(request, 'appId');
    await s.access.requireApp(request.principal, appId, anyOf: writeRoles);
    final body = parseBody(
      await readJsonObject(request),
      UpdateAppRequest.fromJson,
    );
    final name = body.name.trim();
    if (name.isEmpty) throw ApiError.badRequest('App name is required.');
    await s.db.execute(
      'UPDATE apps SET display_name = @n, updated_at = now() WHERE id = @id',
      {'n': name, 'id': appId},
    );
    return noContent();
  }

  Future<Response> deleteApp(Request request) async {
    final appId = pathString(request, 'appId');
    await s.access.requireApp(request.principal, appId, anyOf: adminRoles);
    await s.db.execute('DELETE FROM apps WHERE id = @id', {'id': appId});
    await s.storage.deletePrefix('apps/$appId/');
    return noContent();
  }

  Future<Response> getAppSigningKey(Request request) async {
    final app = await s.access.requireApp(
      request.principal,
      pathString(request, 'appId'),
      anyOf: writeRoles,
    );
    final key = await s.signingKeys.currentFor(app['organization_id'] as int);
    return jsonResponse(
      GetSigningKeyResponse(
        signingKey: SigningKey(id: key.id, publicKeyPem: key.publicKeyPem),
      ).toJson(),
    );
  }

  Future<Response> getChannels(Request request) async {
    final appId = pathString(request, 'appId');
    await s.access.requireApp(request.principal, appId);
    final rows = await s.db.query(
      'SELECT * FROM channels WHERE app_id = @a ORDER BY id',
      {'a': appId},
    );
    return jsonResponse([for (final row in rows) channelFrom(row).toJson()]);
  }

  Future<Response> createChannel(Request request) async {
    final appId = pathString(request, 'appId');
    await s.access.requireApp(request.principal, appId, anyOf: writeRoles);
    final body = parseBody(
      await readJsonObject(request),
      CreateChannelRequest.fromJson,
    );
    final name = body.channel.trim();
    if (name.isEmpty) throw ApiError.badRequest('Channel name is required.');
    final row = await s.db.one(
      'INSERT INTO channels (app_id, name) VALUES (@a, @n) ON CONFLICT DO NOTHING RETURNING *',
      {'a': appId, 'n': name},
    );
    if (row == null) throw ApiError.conflict('Channel $name already exists.');
    return jsonResponse(channelFrom(row).toJson());
  }

  Future<Response> deleteChannel(Request request) async {
    final appId = pathString(request, 'appId');
    await s.access.requireApp(request.principal, appId, anyOf: writeRoles);
    final channelId = pathInt(request, 'channelId');
    final row = await s.db.one(
      'SELECT * FROM channels WHERE id = @id AND app_id = @a',
      {'id': channelId, 'a': appId},
    );
    if (row == null) throw ApiError.notFound('Channel');
    if (row['name'] == 'stable') {
      throw ApiError.badRequest('The stable channel cannot be deleted.');
    }
    // Patches on the channel stay, on no channel (ON DELETE SET NULL).
    await s.db.execute('DELETE FROM channels WHERE id = @id', {
      'id': channelId,
    });
    return noContent();
  }

  // Stubs until per-app roles exist: organization roles apply to every app.

  Future<Response> getAppCollaborators(Request request) async {
    await s.access.requireApp(request.principal, pathString(request, 'appId'));
    return jsonResponse(<Object>[]);
  }

  Future<Response> getAppInvitations(Request request) async {
    await s.access.requireApp(request.principal, pathString(request, 'appId'));
    return jsonResponse(const GetInvitationsResponse(invitations: []).toJson());
  }
}
