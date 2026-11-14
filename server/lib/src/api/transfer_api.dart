import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';

import '../crypto.dart';
import '../forms.dart';
import '../http.dart';
import '../services.dart';
import '../storage.dart';

final _log = Logger('transfer');

enum UploadTarget { releaseArtifact, patchArtifact }

/// Artifact uploads and fs-storage downloads.
///
/// Uploads: the CLI registers an artifact, gets back one of our upload URLs,
/// and sends the bytes there in one of the two ways `code_push_client.dart`
/// knows: a multipart POST with a `file` field, or GCS-style resumable PUTs
/// with `Content-Range` (answered 308 + `Range` until complete). Both are
/// accepted on every upload URL, so the `upload_method` the server
/// advertises only changes what a new client chooses.
class TransferApi {
  TransferApi(this.s);
  final Services s;

  Future<String> createUploadSession(
    Request request, {
    required UploadTarget target,
    required int targetId,
    required String storageKey,
    required int expectedSize,
    String? expectedHash,
  }) async {
    final token = randomToken();
    await s.db.execute(
      'INSERT INTO upload_sessions (token, storage_key, expected_size, expected_hash, target_kind, target_id, expires_at) '
      "VALUES (@t, @k, @size, @hash, @kind, @id, now() + make_interval(secs => @ttl))",
      {
        't': token,
        'k': storageKey,
        'size': expectedSize,
        'hash': expectedHash,
        'kind': target == UploadTarget.releaseArtifact
            ? 'release_artifact'
            : 'patch_artifact',
        'id': targetId,
        'ttl': s.config.uploadSessionTtl.inSeconds,
      },
    );
    return s
        .originFor(request)
        .replace(path: '/api/v1/uploads/$token')
        .toString();
  }

  File _stagingFile(String token) => File(p.join(s.config.stagingDir, token));

  Future<Map<String, dynamic>> _session(String token) async {
    final row = await s.db.one(
      'SELECT * FROM upload_sessions WHERE token = @t AND expires_at > now()',
      {'t': token},
    );
    if (row == null) throw ApiError.notFound('Upload session');
    return row;
  }

  /// POST: a multipart body whose `file` part is the artifact.
  Future<Response> uploadMultipart(Request request) async {
    final token = pathString(request, 'token');
    final session = await _session(token);
    if (session['completed_at'] != null) return Response.ok('');
    if (!isMultipart(request)) {
      throw ApiError.badRequest('Expected multipart/form-data.');
    }
    final staging = _stagingFile(token);
    await staging.parent.create(recursive: true);
    var found = false;
    await for (final part in multipartParts(request)) {
      if (part.name != 'file' || found) {
        await part.stream.drain<void>();
        continue;
      }
      found = true;
      final sink = staging.openWrite();
      await sink.addStream(part.stream);
      await sink.close();
    }
    if (!found) throw ApiError.badRequest('Missing form field "file".');
    await _complete(session, staging);
    return Response.ok('');
  }

  /// PUT: one chunk of a resumable upload, a status query (`bytes */N`), or
  /// a whole body with no Content-Range.
  Future<Response> uploadResumable(Request request) async {
    final token = pathString(request, 'token');
    final session = await _session(token);
    final staging = _stagingFile(token);
    await staging.parent.create(recursive: true);
    if (session['completed_at'] != null) {
      await request.read().drain<void>();
      return Response.ok('');
    }
    var received = session['received'] as int;
    final range = request.headers['content-range'];

    if (range == null) {
      final sink = staging.openWrite();
      await sink.addStream(request.read());
      await sink.close();
      await _complete(session, staging);
      return Response.ok('');
    }

    final query = RegExp(r'^bytes \*/(\d+)$').firstMatch(range);
    if (query != null) {
      return _incomplete(received);
    }
    final chunk = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(range);
    if (chunk == null) {
      throw ApiError.badRequest('Malformed Content-Range: $range');
    }
    final start = int.parse(chunk.group(1)!);
    final end = int.parse(chunk.group(2)!);
    final total = int.parse(chunk.group(3)!);
    final expected = session['expected_size'] as int?;
    if (expected != null && total != expected) {
      await request.read().drain<void>();
      throw ApiError.badRequest(
        'Upload is $total bytes; the artifact was registered as $expected.',
      );
    }
    if (start != received) {
      // Not where we are: tell the client where to resume.
      await request.read().drain<void>();
      return _incomplete(received);
    }
    // Drop anything past `received` (a chunk that failed midway), then append.
    final raf = await staging.open(mode: FileMode.append);
    var written = 0;
    try {
      await raf.truncate(received);
      await raf.setPosition(received);
      await for (final bytes in request.read()) {
        await raf.writeFrom(bytes);
        written += bytes.length;
      }
      if (written != end - start + 1) {
        // Keep only whole chunks; the client re-sends from `received`.
        await raf.truncate(received);
        return _incomplete(received);
      }
    } finally {
      await raf.close();
    }
    received += written;
    await s.db.execute(
      'UPDATE upload_sessions SET received = @r WHERE token = @t',
      {'r': received, 't': token},
    );
    if (received < total) return _incomplete(received);
    await _complete(session, staging);
    return Response.ok('');
  }

  Response _incomplete(int received) => Response(
    308,
    headers: {if (received > 0) 'range': 'bytes=0-${received - 1}'},
  );

  Future<void> _complete(Map<String, dynamic> session, File staging) async {
    final token = session['token'] as String;
    final size = await staging.length();
    final expectedSize = session['expected_size'] as int?;
    final expectedHash = session['expected_hash'] as String?;
    Future<Never> reject(String message) async {
      await staging.delete();
      await s.db.execute(
        'UPDATE upload_sessions SET received = 0 WHERE token = @t',
        {'t': token},
      );
      throw ApiError.badRequest(message, code: 'upload_rejected');
    }

    if (expectedSize != null && size != expectedSize) {
      await reject(
        'Uploaded $size bytes; the artifact was registered as $expectedSize.',
      );
    }
    if (expectedHash != null) {
      final hash = (await sha256.bind(staging.openRead()).first).toString();
      if (hash != expectedHash) {
        await reject('Uploaded file hash does not match the registered hash.');
      }
    }
    await s.storage.putFile(session['storage_key'] as String, staging);
    final table = session['target_kind'] == 'release_artifact'
        ? 'release_artifacts'
        : 'patch_artifacts';
    await s.db.tx((tx) async {
      await tx.execute(
        'UPDATE $table SET uploaded_at = now() WHERE id = \$1',
        parameters: [session['target_id']],
      );
      await tx.execute(
        r'UPDATE upload_sessions SET completed_at = now(), received = $1 WHERE token = $2',
        parameters: [size, token],
      );
    });
    _log.info('Stored ${session['storage_key']} ($size bytes)');
  }

  /// GET/HEAD of an fs-storage object through a signed URL, with single
  /// `Range` support (the updater resumes interrupted patch downloads). No
  /// content encoding: the updater checks the body against Content-Length.
  Future<Response> download(Request request) async {
    final storage = s.storage;
    if (storage is! FsStorage) throw ApiError.notFound('File');
    final key = request.url.path.replaceFirst(RegExp(r'^api/v1/files/'), '');
    final expires = int.tryParse(request.url.queryParameters['expires'] ?? '');
    final sig = request.url.queryParameters['sig'];
    if (expires == null ||
        sig == null ||
        !s.urlSigner.verify('/api/v1/files/$key', expires, sig)) {
      return ApiError(
        403,
        'invalid_signature',
        'This download link is invalid or has expired.',
      ).toResponse();
    }
    final file = storage.fileFor(key);
    if (!await file.exists()) throw ApiError.notFound('File');
    final length = await file.length();
    final headers = <String, String>{
      'content-type': 'application/octet-stream',
      'accept-ranges': 'bytes',
      'cache-control': 'private, max-age=3600',
    };
    var start = 0;
    var end = length - 1;
    var status = 200;
    final range = request.headers['range'];
    if (range != null) {
      final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range.trim());
      if (match == null) {
        return Response(416, headers: {'content-range': 'bytes */$length'});
      }
      final a = match.group(1)!, b = match.group(2)!;
      if (a.isEmpty && b.isNotEmpty) {
        start = length - int.parse(b);
        if (start < 0) start = 0;
      } else if (a.isNotEmpty) {
        start = int.parse(a);
        if (b.isNotEmpty) end = int.parse(b) < end ? int.parse(b) : end;
      }
      if (start >= length || start > end) {
        return Response(416, headers: {'content-range': 'bytes */$length'});
      }
      status = 206;
      headers['content-range'] = 'bytes $start-$end/$length';
    }
    headers['content-length'] = '${end - start + 1}';
    return Response(
      status,
      body: request.method == 'HEAD' ? null : file.openRead(start, end + 1),
      headers: headers,
    );
  }
}
