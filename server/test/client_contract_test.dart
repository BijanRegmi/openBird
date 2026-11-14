import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';
import 'package:test/test.dart';

import 'support/test_server.dart';

/// Drives the server with Shorebird's own CodePushClient (same pinned SHA as
/// the protocol), the way `shorebird init`, `release`, `patch` and `patches`
/// do, then checks what a device's updater would see.
void main() {
  late TestServer server;
  late CodePushClient client;
  late Directory files;

  setUpAll(() async {
    server = await TestServer.start();
    client = CodePushClient(
      hostedUri: server.uri,
      customHeaders: {'authorization': 'Bearer ${server.apiKey}'},
      uploadRetryBaseDelay: Duration.zero,
    );
    files = await Directory.systemTemp.createTemp('artifacts');
  });
  tearDownAll(() async {
    client.close();
    await server.stop();
    await files.delete(recursive: true);
  });

  Future<File> artifact(String name, int size, int seed) async {
    final bytes = Uint8List(size);
    for (var i = 0; i < size; i++) {
      bytes[i] = (i * 31 + seed) & 0xff;
    }
    return File('${files.path}/$name')..writeAsBytesSync(bytes);
  }

  Future<Map<String, dynamic>> patchCheck({
    String clientId = 'install-1',
    String arch = 'x86_64',
  }) async {
    final response = await http.post(
      server.uri.replace(path: '/api/v1/patches/check'),
      body: jsonEncode({
        'app_id': appIdOf,
        'channel': 'stable',
        'release_version': '1.0.0+1',
        'platform': 'android',
        'arch': arch,
        'client_id': clientId,
      }),
    );
    expect(response.statusCode, 200);
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  test('anonymous API calls are refused with an ErrorResponse', () async {
    final anonymous = CodePushClient(hostedUri: server.uri);
    await expectLater(anonymous.getApps(), throwsA(isA<CodePushException>()));
    anonymous.close();
  });

  test('init: current user, organizations, create app', () async {
    final user = await client.getCurrentUser();
    expect(user!.email, 'dev@example.com');
    final orgs = await client.getOrganizationMemberships();
    expect(orgs.single.role, Role.owner);
    final app = await client.createApp(
      displayName: 'Sample',
      organizationId: orgs.single.organization.id,
    );
    appIdOf = app.id;
    final apps = await client.getApps();
    expect(apps.single.appId, app.id);
    expect((await client.getChannels(appId: app.id)).single.name, 'stable');
  });

  test(
    'release: managed key, draft, artifacts (resumable multi-chunk), active',
    () async {
      final key = await client.getSigningKey(appId: appIdOf);
      expect(key.publicKeyPem, startsWith('-----BEGIN PUBLIC KEY-----'));
      expect(
        (await client.getSigningKey(appId: appIdOf)).id,
        key.id,
        reason: 'stable per org',
      );
      managedPem = key.publicKeyPem;

      final release = await client.createRelease(
        appId: appIdOf,
        version: '1.0.0+1',
        flutterRevision: 'abc123',
        flutterVersion: '3.47.9',
      );
      releaseId = release.id;
      await expectLater(
        client.createRelease(
          appId: appIdOf,
          version: '1.0.0+1',
          flutterRevision: 'abc123',
        ),
        throwsA(isA<CodePushConflictException>()),
      );
      await client.updateReleaseStatus(
        appId: appIdOf,
        releaseId: release.id,
        platform: ReleasePlatform.android,
        status: ReleaseStatus.draft,
      );
      // Over the client's 8 MiB chunk size, so it takes two resumable PUTs.
      final aab = await artifact('app.aab', 9 * 1024 * 1024 + 123, 1);
      final so = await artifact('libapp.so', 4096, 2);
      for (final (file, arch) in [(aab, 'aab'), (so, 'x86_64')]) {
        await client.createReleaseArtifact(
          artifactPath: file.path,
          appId: appIdOf,
          releaseId: release.id,
          arch: arch,
          platform: ReleasePlatform.android,
          hash: sha256.convert(file.readAsBytesSync()).toString(),
          canSideload: true,
          podfileLockHash: null,
          signing: ArtifactSigningRequest(
            mode: ReleaseSigningMode.managed,
            keyId: key.id,
          ),
        );
      }
      // A retry while the release is a draft uploads over the artifact.
      await client.createReleaseArtifact(
        artifactPath: so.path,
        appId: appIdOf,
        releaseId: release.id,
        arch: 'x86_64',
        platform: ReleasePlatform.android,
        hash: sha256.convert(so.readAsBytesSync()).toString(),
        canSideload: true,
        podfileLockHash: null,
        signing: ArtifactSigningRequest(
          mode: ReleaseSigningMode.managed,
          keyId: key.id,
        ),
      );
      await client.updateReleaseStatus(
        appId: appIdOf,
        releaseId: release.id,
        platform: ReleasePlatform.android,
        status: ReleaseStatus.active,
        metadata: {'generatedApks': false},
      );
      // Once active, artifacts are final; the CLI treats 409 as "exists".
      await expectLater(
        client.createReleaseArtifact(
          artifactPath: so.path,
          appId: appIdOf,
          releaseId: release.id,
          arch: 'x86_64',
          platform: ReleasePlatform.android,
          hash: sha256.convert(so.readAsBytesSync()).toString(),
          canSideload: true,
          podfileLockHash: null,
        ),
        throwsA(isA<CodePushConflictException>()),
      );

      final releases = await client.getReleases(appId: appIdOf);
      final details = releases.single.platforms[ReleasePlatform.android]!;
      expect(details.status, ReleaseStatus.active);
      expect(details.signingMode, 'managed');

      final artifacts = await client.getReleaseArtifacts(
        appId: appIdOf,
        releaseId: release.id,
        platform: ReleasePlatform.android,
      );
      expect(artifacts.map((a) => a.arch), unorderedEquals(['aab', 'x86_64']));
      final aabArtifact = artifacts.firstWhere((a) => a.arch == 'aab');
      expect(aabArtifact.signing!.publicKeyPem, key.publicKeyPem);
      // The CLI downloads release artifacts without credentials.
      final download = await http.get(Uri.parse(aabArtifact.url));
      expect(download.statusCode, 200);
      expect(sha256.convert(download.bodyBytes).toString(), aabArtifact.hash);
      final tampered = Uri.parse(aabArtifact.url).replace(
        queryParameters: {
          ...Uri.parse(aabArtifact.url).queryParameters,
          'sig': 'x',
        },
      );
      expect((await http.get(tampered)).statusCode, 403);
    },
  );

  test(
    'patch: create, upload (multipart and resumable), promote; device gets it signed',
    () async {
      expect(await patchCheck(), {'patch_available': false});
      final patch = await client.createPatch(
        appId: appIdOf,
        releaseId: releaseId,
        metadata: {'a': 1},
      );
      expect(patch.number, 1);
      final diff = await artifact('patch.bin', 2048, 3);
      const patchedHash =
          'aa3b9f1c40bd2c3ee6e1c4b1c25c6c7d0d9b7d0f9b9f3b2e6c3a2d1c0b9a8f7e';
      await client.createPatchArtifact(
        artifactPath: diff.path,
        appId: appIdOf,
        patchId: patch.id,
        arch: 'x86_64',
        platform: ReleasePlatform.android,
        hash: patchedHash,
      );
      // Not on a channel yet: devices see nothing.
      expect((await patchCheck())['patch_available'], isFalse);
      final stable = (await client.getChannels(appId: appIdOf)).single;
      await client.promotePatch(
        appId: appIdOf,
        patchId: patch.id,
        channelId: stable.id,
      );

      final check = await patchCheck();
      expect(check['patch_available'], isTrue);
      final offered = check['patch'] as Map<String, dynamic>;
      expect(offered['number'], 1);
      expect(offered['hash'], patchedHash);
      expect(
        _verify(managedPem, patchedHash, offered['hash_signature'] as String),
        isTrue,
      );
      expect((await patchCheck(arch: 'aarch64'))['patch_available'], isFalse);

      // The updater resumes interrupted downloads with Range.
      final url = Uri.parse(offered['download_url'] as String);
      final full = await http.get(url);
      expect(full.bodyBytes, diff.readAsBytesSync());
      final rest = await http.get(url, headers: {'range': 'bytes=1000-'});
      expect(rest.statusCode, 206);
      expect(rest.headers['content-length'], '1048');
      expect(rest.bodyBytes, diff.readAsBytesSync().sublist(1000));

      final patches = await client.getPatches(
        appId: appIdOf,
        releaseId: releaseId,
      );
      expect(patches.single.channel, 'stable');
      expect(patches.single.rolloutPercentage, 100);
      expect(patches.single.artifacts.single.hash, patchedHash);
    },
  );

  test(
    'rollout: a partial patch reaches only its cohort; rollouts only go up',
    () async {
      final patch = await client.createPatch(
        appId: appIdOf,
        releaseId: releaseId,
        metadata: {},
      );
      final diff = await artifact('patch2.bin', 100, 4);
      await client.createPatchArtifact(
        artifactPath: diff.path,
        appId: appIdOf,
        patchId: patch.id,
        arch: 'x86_64',
        platform: ReleasePlatform.android,
        hash: 'b' * 64,
      );
      final stable = (await client.getChannels(appId: appIdOf)).single;
      await client.promotePatch(
        appId: appIdOf,
        patchId: patch.id,
        channelId: stable.id,
        rolloutPercentage: 30,
      );
      var two = 0;
      for (var i = 0; i < 200; i++) {
        final number =
            ((await patchCheck(clientId: 'c$i'))['patch'] as Map)['number'];
        if (number == 2) two++;
        expect(
          number,
          anyOf(1, 2),
          reason: 'outside the cohort, patch 1 still applies',
        );
      }
      expect(two, inInclusiveRange(35, 85));
      await expectLater(
        client.setPatchRollout(
          appId: appIdOf,
          releaseId: releaseId,
          patchId: patch.id,
          rolloutPercentage: 10,
        ),
        throwsA(isA<CodePushConflictException>()),
      );
      await client.setPatchRollout(
        appId: appIdOf,
        releaseId: releaseId,
        patchId: patch.id,
        rolloutPercentage: 100,
      );
      expect(
        ((await patchCheck(clientId: 'anyone'))['patch'] as Map)['number'],
        2,
      );
      rolloutPatchId = patch.id;
    },
  );

  test('rollback and rollforward', () async {
    expect(
      await client.rollbackPatch(
        appId: appIdOf,
        releaseId: releaseId,
        patchId: rolloutPatchId,
      ),
      isTrue,
    );
    expect(
      await client.rollbackPatch(
        appId: appIdOf,
        releaseId: releaseId,
        patchId: rolloutPatchId,
      ),
      isFalse,
    );
    final check = await patchCheck();
    expect((check['patch'] as Map)['number'], 1);
    expect(check['rolled_back_patch_numbers'], [2]);
    expect(
      await client.rollforwardPatch(
        appId: appIdOf,
        releaseId: releaseId,
        patchId: rolloutPatchId,
      ),
      isTrue,
    );
    expect(((await patchCheck())['patch'] as Map)['number'], 2);
  });

  test('updater events are recorded once per event_id', () async {
    final event = {
      'event': {
        'app_id': appIdOf,
        'arch': 'x86_64',
        'client_id': 'install-1',
        'type': '__patch_install__',
        'patch_number': 2,
        'platform': 'android',
        'release_version': '1.0.0+1',
        'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'message': null,
        'event_id': 'e-1',
      },
    };
    for (var i = 0; i < 2; i++) {
      final r = await http.post(
        server.uri.replace(path: '/api/v1/patches/events'),
        body: jsonEncode(event),
      );
      expect(r.statusCode, 201);
    }
    final rows = await server.db.query(
      "SELECT * FROM patch_events WHERE event_id = 'e-1'",
    );
    expect(rows, hasLength(1));
    final usage = await client.getOrganizationUsage(
      organizationId: server.orgId,
    );
    expect(usage.apps.single.patchInstallCount, 1);
  });

  test('build runs are accepted', () async {
    final run = await client.createBuildRun(
      appId: appIdOf,
      request: CreateBuildRunRequest(
        runId: 'r1',
        command: BuildRunCommand.patch,
        platform: ReleasePlatform.android,
        outcome: BuildRunOutcome.succeeded,
        startedAt: DateTime.now().toUtc(),
        durationMs: 10,
        dryRun: false,
      ),
    );
    expect(run.id, isPositive);
  });

  test('unsupported operations answer 501 with an ErrorResponse', () async {
    final r = await http.get(
      server.uri.replace(path: '/api/v1/enterprises'),
      headers: {'authorization': 'Bearer ${server.apiKey}'},
    );
    expect(r.statusCode, 501);
    expect((jsonDecode(r.body) as Map)['code'], 'unsupported_operation');
  });

  test('deleting the release removes its patches', () async {
    await client.deleteRelease(appId: appIdOf, releaseId: releaseId);
    expect(await patchCheck(), {'patch_available': false});
    await client.deleteApp(appId: appIdOf);
    expect(await client.getApps(), isEmpty);
  });
}

late String appIdOf;
late int releaseId;
late String managedPem;
late int rolloutPatchId;

/// Verifies like the updater: RSASSA-PKCS1-v1_5/SHA-256 over the hash string.
bool _verify(String pem, String message, String signature) {
  final der = base64.decode(
    pem.split('\n').where((l) => l.isNotEmpty && !l.startsWith('-----')).join(),
  );
  // SubjectPublicKeyInfo → RSAPublicKey (modulus, exponent).
  final spki = ASN1Parser(der).nextObject() as ASN1Sequence;
  final bits = spki.elements![1] as ASN1BitString;
  final rsa =
      ASN1Parser(Uint8List.fromList(bits.stringValues!)).nextObject()
          as ASN1Sequence;
  final key = RSAPublicKey(
    (rsa.elements![0] as ASN1Integer).integer!,
    (rsa.elements![1] as ASN1Integer).integer!,
  );
  final verifier = Signer('SHA-256/RSA')
    ..init(false, PublicKeyParameter<RSAPublicKey>(key));
  return verifier.verifySignature(
    Uint8List.fromList(utf8.encode(message)),
    RSASignature(base64.decode(signature)),
  );
}
