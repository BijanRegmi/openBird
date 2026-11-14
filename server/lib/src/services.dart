import 'dart:typed_data';

import 'package:shelf/shelf.dart';

import 'auth.dart';
import 'config.dart';
import 'crypto.dart';
import 'db.dart';
import 'storage.dart';

/// Everything the handlers share.
class Services {
  Services({required this.config, required this.db, required this.storage})
    : access = Access(db),
      apiKeys = ApiKeys(db),
      sessions = Sessions(db),
      urlSigner = UrlSigner(config.masterKey),
      signingKeys = SigningKeys(
        db,
        SecretBox(deriveKey(config.masterKey, 'signing-keys-v1')),
      );

  final Config config;
  final Db db;
  final Storage storage;
  final Access access;
  final ApiKeys apiKeys;
  final Sessions sessions;
  final UrlSigner urlSigner;
  final SigningKeys signingKeys;

  /// The origin URLs in a response to [request] should use: PUBLIC_URL, or
  /// the origin the client used to reach this server.
  Uri originFor(Request request) {
    final configured = config.publicUrl;
    if (configured != null) return configured;
    final headers = request.headers;
    final scheme = config.trustProxy
        ? (headers['x-forwarded-proto']?.split(',').first.trim() ??
              request.requestedUri.scheme)
        : request.requestedUri.scheme;
    final host = config.trustProxy
        ? (headers['x-forwarded-host']?.split(',').first.trim() ??
              headers['host'])
        : headers['host'];
    if (host == null) {
      return request.requestedUri.replace(path: '', query: null);
    }
    return Uri.parse('$scheme://$host');
  }

  Future<String> downloadUrl(Request request, String storageKey) =>
      storage.downloadUrl(
        storageKey,
        origin: originFor(request),
        ttl: config.downloadUrlTtl,
      );
}

/// Managed patch-signing keys: one current key per organization, created on
/// first use, private half encrypted at rest.
class SigningKeys {
  SigningKeys(this._db, this._box);

  final Db _db;
  final SecretBox _box;

  Future<({int id, String publicKeyPem})> currentFor(int organizationId) async {
    final existing = await _db.one(
      'SELECT id, public_key_pem FROM signing_keys '
      'WHERE organization_id = @o AND retired_at IS NULL',
      {'o': organizationId},
    );
    if (existing != null) {
      return (
        id: existing['id'] as int,
        publicKeyPem: existing['public_key_pem'] as String,
      );
    }
    final key = ManagedSigningKey.generate();
    final row = await _db.one(
      'INSERT INTO signing_keys (organization_id, public_key_pem, private_key_enc) '
      'VALUES (@o, @pem, @enc) '
      // A concurrent first call may have created it; keep theirs.
      'ON CONFLICT (organization_id) WHERE retired_at IS NULL DO NOTHING '
      'RETURNING id, public_key_pem',
      {
        'o': organizationId,
        'pem': key.publicKeyPem,
        'enc': _box.seal(key.serializePrivate()),
      },
    );
    if (row == null) return currentFor(organizationId);
    return (
      id: row['id'] as int,
      publicKeyPem: row['public_key_pem'] as String,
    );
  }

  Future<String?> publicKeyPem(int keyId) async {
    final row = await _db.one(
      'SELECT public_key_pem FROM signing_keys WHERE id = @id',
      {'id': keyId},
    );
    return row?['public_key_pem'] as String?;
  }

  Future<String> sign(int keyId, String message) async {
    final row = await _db.one(
      'SELECT private_key_enc FROM signing_keys WHERE id = @id',
      {'id': keyId},
    );
    if (row == null) throw StateError('Signing key $keyId not found');
    final key = ManagedSigningKey.fromSerialized(
      _box.open(Uint8List.fromList(row['private_key_enc'] as List<int>)),
    );
    return key.sign(message);
  }
}
