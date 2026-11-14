import 'dart:convert';

import 'package:openbird_server/openbird_server.dart' show PasswordHasher;
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support/test_server.dart';

/// The console's own routes (/console/v1), cookie sessions, and the spec's
/// members and metrics operations as the console uses them.
void main() {
  late TestServer server;

  setUpAll(() async => server = await TestServer.start());
  tearDownAll(() => server.stop());

  Uri u(String path, [Map<String, String>? q]) =>
      server.uri.replace(path: path, queryParameters: q);

  Future<http.Response> send(
    String method,
    String path, {
    Object? body,
    String? cookie,
    bool consoleHeader = true,
    String? bearer,
  }) {
    final request = http.Request(method, u(path))
      ..headers.addAll({
        if (cookie != null) 'cookie': cookie,
        if (consoleHeader) 'x-openbird-console': '1',
        if (bearer != null) 'authorization': 'Bearer $bearer',
      });
    if (body != null) request.body = jsonEncode(body);
    return request.send().then(http.Response.fromStream);
  }

  String sessionOf(http.Response r) =>
      r.headers['set-cookie']!.split(';').first;

  test('sign-up is closed once an account exists, open for invitees', () async {
    // TestServer already created dev@example.com.
    final closed = await send(
      'POST',
      '/console/v1/signup',
      body: {
        'email': 'stranger@example.com',
        'password': 'long-enough-password',
      },
    );
    expect(closed.statusCode, 403);
    final config =
        jsonDecode((await send('GET', '/console/v1/config')).body) as Map;
    expect(config['signup_allowed'], isFalse);
  });

  test(
    'password sign-in sets an HttpOnly session; writes need the console header',
    () async {
      await server.db.execute(
        "UPDATE users SET password_hash = @h WHERE email = 'dev@example.com'",
        {'h': _hash},
      );
      final bad = await send(
        'POST',
        '/console/v1/session',
        body: {'email': 'dev@example.com', 'password': 'nope'},
      );
      expect(bad.statusCode, 401);
      final ok = await send(
        'POST',
        '/console/v1/session',
        body: {'email': 'DEV@example.com', 'password': 'correct horse battery'},
      );
      expect(ok.statusCode, 200);
      expect(ok.headers['set-cookie'], contains('HttpOnly'));
      final cookie = sessionOf(ok);

      final me = await send('GET', '/console/v1/session', cookie: cookie);
      expect((jsonDecode(me.body) as Map)['email'], 'dev@example.com');
      // The protocol API accepts the session too.
      expect(
        (await send('GET', '/api/v1/apps', cookie: cookie)).statusCode,
        200,
      );
      // CSRF: a cookie-authenticated write without the header is refused.
      final forged = await send(
        'POST',
        '/console/v1/api-keys',
        cookie: cookie,
        consoleHeader: false,
        body: {'name': 'x'},
      );
      expect(forged.statusCode, 403);

      final created = await send(
        'POST',
        '/console/v1/api-keys',
        cookie: cookie,
        body: {'name': 'CI'},
      );
      expect(created.statusCode, 201);
      final key = (jsonDecode(created.body) as Map)['key'] as String;
      expect(key, startsWith('sb_api_'));
      expect(
        (await send(
          'GET',
          '/api/v1/users/me',
          bearer: key,
          consoleHeader: false,
        )).statusCode,
        200,
      );
      final keys =
          jsonDecode(
                (await send(
                  'GET',
                  '/console/v1/api-keys',
                  cookie: cookie,
                )).body,
              )
              as List;
      final id =
          (keys.firstWhere((k) => (k as Map)['name'] == 'CI') as Map)['id'];
      expect(
        (await send(
          'DELETE',
          '/console/v1/api-keys/$id',
          cookie: cookie,
        )).statusCode,
        204,
      );
      expect(
        (await send(
          'GET',
          '/api/v1/users/me',
          bearer: key,
          consoleHeader: false,
        )).statusCode,
        401,
      );

      expect(
        (await send(
          'DELETE',
          '/console/v1/session',
          cookie: cookie,
        )).statusCode,
        204,
      );
      expect(
        (await send('GET', '/console/v1/session', cookie: cookie)).statusCode,
        401,
      );
    },
  );

  test(
    'invite, sign up with the invited email, accept, change role, keep an owner',
    () async {
      final orgPath = '/api/v1/organizations/${server.orgId}';
      final invite = await send(
        'POST',
        '$orgPath/invitations',
        bearer: server.apiKey,
        body: {'email': 'new@example.com', 'role': 'developer'},
      );
      expect(invite.statusCode, 201);
      expect((jsonDecode(invite.body) as Map)['type'], 'invitation');

      final signup = await send(
        'POST',
        '/console/v1/signup',
        body: {
          'email': 'new@example.com',
          'password': 'invited-user-password',
          'name': 'New',
        },
      );
      expect(signup.statusCode, 201);
      final cookie = sessionOf(signup);
      final received =
          jsonDecode(
                (await send('GET', '/api/v1/invitations', cookie: cookie)).body,
              )
              as Map;
      final invitation = (received['invitations'] as List).single as Map;
      expect(invitation['target_name'], 'Dev');
      expect(
        (await send(
          'POST',
          '/api/v1/invitations/${invitation['id']}/accept',
          cookie: cookie,
        )).statusCode,
        204,
      );

      final users =
          jsonDecode(
                (await send(
                  'GET',
                  '$orgPath/users',
                  bearer: server.apiKey,
                )).body,
              )
              as Map;
      final member = (users['users'] as List).cast<Map>().firstWhere(
        (u) => (u['user'] as Map)['email'] == 'new@example.com',
      );
      expect(member['role'], 'developer');
      final userId = (member['user'] as Map)['id'];
      // A developer can't manage members.
      expect(
        (await send(
          'PATCH',
          '$orgPath/users/$userId',
          cookie: cookie,
          body: {'role': 'owner'},
        )).statusCode,
        403,
      );
      expect(
        (await send(
          'PATCH',
          '$orgPath/users/$userId',
          bearer: server.apiKey,
          body: {'role': 'admin'},
        )).statusCode,
        204,
      );
      // The only owner can't be demoted.
      final owner = (users['users'] as List).cast<Map>().firstWhere(
        (u) => u['role'] == 'owner',
      );
      final demote = await send(
        'PATCH',
        '$orgPath/users/${(owner['user'] as Map)['id']}',
        bearer: server.apiKey,
        body: {'role': 'viewer'},
      );
      expect(demote.statusCode, 400);
      // Inviting an existing account adds it directly.
      await send('DELETE', '$orgPath/users/$userId', bearer: server.apiKey);
      final readd = await send(
        'POST',
        '$orgPath/invitations',
        bearer: server.apiKey,
        body: {'email': 'new@example.com', 'role': 'viewer'},
      );
      expect((jsonDecode(readd.body) as Map)['type'], 'member');
    },
  );

  test('metrics come from patch-check activity and events', () async {
    final app =
        jsonDecode(
              (await send(
                'POST',
                '/api/v1/apps',
                bearer: server.apiKey,
                body: {
                  'display_name': 'Metrics',
                  'organization_id': server.orgId,
                },
              )).body,
            )
            as Map;
    final appId = app['id'] as String;
    for (var i = 0; i < 3; i++) {
      await http.post(
        u('/api/v1/patches/check'),
        body: jsonEncode({
          'app_id': appId,
          'channel': 'stable',
          'release_version': i == 0 ? '1.0.0' : '1.1.0',
          'platform': i == 2 ? 'ios' : 'android',
          'arch': 'aarch64',
          'client_id': 'device-$i',
          'current_patch_number': i == 0 ? null : 1,
        }),
      );
    }
    // Activity is recorded off the request path.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    Future<Map> metric(String name, [Map<String, String>? q]) async =>
        jsonDecode(
              (await http.get(
                u('/api/v1/apps/$appId/metrics/$name', q),
                headers: {'authorization': 'Bearer ${server.apiKey}'},
              )).body,
            )
            as Map;

    final users = await metric('unique-users', {
      'granularity': 'day',
      'group_by': 'platform',
    });
    expect((users['current'] as Map)['unique_users'], 3);
    final breakdown = {
      for (final b in (users['current'] as Map)['breakdown'] as List)
        (b as Map)['group_value']: b['unique_users'],
    };
    expect(breakdown, {'android': 2, 'ios': 1});
    final versions = await metric('version-distribution');
    expect(versions['total_devices'], 3);
    expect(
      (versions['entries'] as List).first,
      containsPair('release_version', '1.1.0'),
    );
    expect((await metric('new-devices'))['current'], 3);
    final hours = await metric('active-hours');
    expect((hours['hourly'] as List), hasLength(24));
    expect(hours['busiest_hour_utc'], DateTime.now().toUtc().hour);
    expect(((await metric('activity-heatmap'))['cells'] as List), isNotEmpty);
  });
}

final _hash = PasswordHasher.hash('correct horse battery');
