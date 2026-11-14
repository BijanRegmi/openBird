import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';

final _random = Random.secure();

Uint8List randomBytes(int length) =>
    Uint8List.fromList(List<int>.generate(length, (_) => _random.nextInt(256)));

/// URL-safe random token without padding.
String randomToken([int bytes = 32]) =>
    base64Url.encode(randomBytes(bytes)).replaceAll('=', '');

/// A random (version 4) UUID, used for app ids like Shorebird's.
String uuidV4() {
  final b = randomBytes(16);
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

String sha256Hex(List<int> bytes) => crypto.sha256.convert(bytes).toString();

/// Derives an independent subkey of the master key for [purpose], so the
/// key that encrypts signing keys never also signs URLs.
Uint8List deriveKey(Uint8List masterKey, String purpose) => Uint8List.fromList(
  crypto.Hmac(crypto.sha256, masterKey).convert(utf8.encode(purpose)).bytes,
);

/// AES-256-GCM. Output is nonce (12 bytes) followed by ciphertext and tag.
class SecretBox {
  SecretBox(this._key) : assert(_key.length == 32);

  final Uint8List _key;

  Uint8List seal(Uint8List plaintext) {
    final nonce = randomBytes(12);
    final cipher = GCMBlockCipher(
      AESEngine(),
    )..init(true, AEADParameters(KeyParameter(_key), 128, nonce, Uint8List(0)));
    return Uint8List.fromList([...nonce, ...cipher.process(plaintext)]);
  }

  Uint8List open(Uint8List sealed) {
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        false,
        AEADParameters(
          KeyParameter(_key),
          128,
          sealed.sublist(0, 12),
          Uint8List(0),
        ),
      );
    return cipher.process(sealed.sublist(12));
  }
}

/// RSA keys for Shorebird managed patch signing.
///
/// The updater verifies RSASSA-PKCS1-v1_5 with SHA-256 over the UTF-8 bytes
/// of the patch's hex `hash` (updater `cache/signing.rs`), against the public
/// key the release embeds. The CLI fetches that key as SubjectPublicKeyInfo
/// PEM and converts it for embedding itself.
class ManagedSigningKey {
  ManagedSigningKey._(this.publicKey, this.privateKey);

  factory ManagedSigningKey.generate({int bits = 2048}) {
    final secureRandom = FortunaRandom()..seed(KeyParameter(randomBytes(32)));
    final generator = RSAKeyGenerator()
      ..init(
        ParametersWithRandom(
          RSAKeyGeneratorParameters(BigInt.from(65537), bits, 64),
          secureRandom,
        ),
      );
    final pair = generator.generateKeyPair();
    return ManagedSigningKey._(
      pair.publicKey as RSAPublicKey,
      pair.privateKey as RSAPrivateKey,
    );
  }

  /// Restores a key from [serializePrivate]'s output.
  factory ManagedSigningKey.fromSerialized(Uint8List bytes) {
    final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    BigInt n(String k) => BigInt.parse(json[k] as String, radix: 16);
    final privateKey = RSAPrivateKey(n('n'), n('d'), n('p'), n('q'));
    return ManagedSigningKey._(RSAPublicKey(n('n'), n('e')), privateKey);
  }

  final RSAPublicKey publicKey;
  final RSAPrivateKey privateKey;

  Uint8List serializePrivate() => utf8.encode(
    jsonEncode({
      'n': privateKey.modulus!.toRadixString(16),
      'e': publicKey.exponent!.toRadixString(16),
      'd': privateKey.privateExponent!.toRadixString(16),
      'p': privateKey.p!.toRadixString(16),
      'q': privateKey.q!.toRadixString(16),
    }),
  );

  /// `-----BEGIN PUBLIC KEY-----` (SubjectPublicKeyInfo) PEM.
  String get publicKeyPem {
    final rsaPublicKey = ASN1Sequence(
      elements: [
        ASN1Integer(publicKey.modulus),
        ASN1Integer(publicKey.exponent),
      ],
    )..encode();
    final spki = ASN1Sequence(
      elements: [
        ASN1Sequence(
          elements: [
            ASN1ObjectIdentifier.fromIdentifierString('1.2.840.113549.1.1.1'),
            ASN1Null(),
          ],
        ),
        ASN1BitString(stringValues: rsaPublicKey.encodedBytes),
      ],
    );
    final b64 = base64.encode(spki.encode());
    final lines = [
      for (var i = 0; i < b64.length; i += 64)
        b64.substring(i, min(i + 64, b64.length)),
    ];
    return '-----BEGIN PUBLIC KEY-----\n${lines.join('\n')}\n-----END PUBLIC KEY-----\n';
  }

  /// Base64 RSASSA-PKCS1-v1_5/SHA-256 signature of [message]'s UTF-8 bytes.
  String sign(String message) {
    final signer = Signer('SHA-256/RSA')
      ..init(true, PrivateKeyParameter<RSAPrivateKey>(privateKey));
    final signature =
        signer.generateSignature(Uint8List.fromList(utf8.encode(message)))
            as RSASignature;
    return base64.encode(signature.bytes);
  }

  bool verify(String message, String signatureBase64) {
    final verifier = Signer('SHA-256/RSA')
      ..init(false, PublicKeyParameter<RSAPublicKey>(publicKey));
    try {
      return verifier.verifySignature(
        Uint8List.fromList(utf8.encode(message)),
        RSASignature(base64.decode(signatureBase64)),
      );
    } on Object {
      return false;
    }
  }
}

/// Signs URLs the server serves itself, so they work without an
/// Authorization header (the CLI downloads with an unauthenticated client,
/// and the updater never authenticates).
class UrlSigner {
  UrlSigner(Uint8List masterKey)
    : _key = deriveKey(masterKey, 'url-signing-v1');

  final Uint8List _key;

  String signature(String path, int expiresEpochSeconds) => base64Url
      .encode(
        crypto.Hmac(
          crypto.sha256,
          _key,
        ).convert(utf8.encode('$path\n$expiresEpochSeconds')).bytes,
      )
      .replaceAll('=', '');

  bool verify(String path, int expiresEpochSeconds, String signature) {
    if (DateTime.now().millisecondsSinceEpoch ~/ 1000 > expiresEpochSeconds) {
      return false;
    }
    final expected = this.signature(path, expiresEpochSeconds);
    if (expected.length != signature.length) return false;
    var diff = 0;
    for (var i = 0; i < expected.length; i++) {
      diff |= expected.codeUnitAt(i) ^ signature.codeUnitAt(i);
    }
    return diff == 0;
  }
}

/// PBKDF2-HMAC-SHA256 password hashes: `pbkdf2-sha256$<iterations>$<salt>$<hash>`.
class PasswordHasher {
  static const _iterations = 210000;

  static Uint8List _derive(String password, Uint8List salt, int iterations) {
    final derivator = KeyDerivator('SHA-256/HMAC/PBKDF2')
      ..init(Pbkdf2Parameters(salt, iterations, 32));
    return derivator.process(Uint8List.fromList(utf8.encode(password)));
  }

  static String hash(String password) {
    final salt = randomBytes(16);
    final key = _derive(password, salt, _iterations);
    return 'pbkdf2-sha256\$$_iterations\$${base64.encode(salt)}\$${base64.encode(key)}';
  }

  static bool verify(String password, String encoded) {
    final parts = encoded.split(r'$');
    if (parts.length != 4 || parts[0] != 'pbkdf2-sha256') return false;
    final iterations = int.tryParse(parts[1]);
    if (iterations == null) return false;
    final expected = base64.decode(parts[3]);
    final actual = _derive(password, base64.decode(parts[2]), iterations);
    if (actual.length != expected.length) return false;
    var diff = 0;
    for (var i = 0; i < actual.length; i++) {
      diff |= actual[i] ^ expected[i];
    }
    return diff == 0;
  }
}
