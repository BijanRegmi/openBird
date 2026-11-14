import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:openbird_server/src/crypto.dart';
import 'package:test/test.dart';

void main() {
  final key = ManagedSigningKey.generate();
  const hash =
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

  test('signatures verify, and survive serialization', () {
    final restored = ManagedSigningKey.fromSerialized(key.serializePrivate());
    final signature = restored.sign(hash);
    expect(key.verify(hash, signature), isTrue);
    expect(key.verify('0' * 64, signature), isFalse);
  });

  // The updater verifies RSASSA-PKCS1-v1_5/SHA-256 over the hash string;
  // openssl checks the same thing independently of pointycastle.
  test(
    'openssl accepts the public key PEM and the signature',
    () async {
      final dir = await Directory.systemTemp.createTemp('sig');
      addTearDown(() => dir.delete(recursive: true));
      File('${dir.path}/pub.pem').writeAsStringSync(key.publicKeyPem);
      File('${dir.path}/msg').writeAsStringSync(hash);
      final sig = ManagedSigningKey.fromSerialized(
        key.serializePrivate(),
      ).sign(hash);
      File('${dir.path}/sig').writeAsBytesSync(base64.decode(sig));
      final result = await Process.run('openssl', [
        'dgst',
        '-sha256',
        '-verify',
        '${dir.path}/pub.pem',
        '-signature',
        '${dir.path}/sig',
        '${dir.path}/msg',
      ]);
      expect(
        result.stdout.toString().trim(),
        'Verified OK',
        reason: '${result.stderr}',
      );
    },
    skip: Process.runSync('which', ['openssl']).exitCode != 0
        ? 'no openssl'
        : null,
  );

  test('SecretBox round-trips and detects tampering', () {
    final box = SecretBox(randomBytes(32));
    final sealed = box.seal(Uint8List.fromList([1, 2, 3]));
    expect(box.open(sealed), [1, 2, 3]);
    sealed[sealed.length - 1] ^= 1;
    expect(() => box.open(sealed), throwsA(anything));
  });

  test('signed URLs verify only unchanged and unexpired', () {
    final signer = UrlSigner(randomBytes(32));
    final exp = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 60;
    final sig = signer.signature('/api/v1/files/a', exp);
    expect(signer.verify('/api/v1/files/a', exp, sig), isTrue);
    expect(signer.verify('/api/v1/files/b', exp, sig), isFalse);
    expect(
      signer.verify(
        '/api/v1/files/a',
        exp - 120,
        signer.signature('/api/v1/files/a', exp - 120),
      ),
      isFalse,
    );
  });
}
