import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

import '../config.dart';
import '../storage.dart';

/// Azure Blob Storage, over the Blob service REST API. The server signs its
/// own requests with the account's shared key; downloads are read-only
/// service SAS URLs for a single blob, which Azure serves with Range support
/// and without content encoding.
class AzureBlobStorage implements Storage {
  AzureBlobStorage(this.config, {HttpClient? client})
    : _client = client ?? HttpClient(),
      _key = base64.decode(config.accountKey);

  final AzureBlobStorageConfig config;
  final HttpClient _client;
  final List<int> _key;

  /// The REST API version requests and SAS tokens are made for.
  static const apiVersion = '2021-08-06';

  /// Blobs deleted at once by [deletePrefix].
  static const _deleteConcurrency = 16;

  @override
  Future<void> init() async {
    final response = await _send(
      'PUT',
      _containerUri({'restype': 'container'}),
      contentLength: 0,
    );
    // 409 ContainerAlreadyExists is the steady state.
    if (response.statusCode != 201 && response.statusCode != 409) {
      throw await _error('create container ${config.container}', response);
    }
    await response.drain<void>();
  }

  @override
  Future<void> putFile(String key, File file) async {
    final response = await _send(
      'PUT',
      _blobUri(config.endpoint, key),
      headers: {'x-ms-blob-type': 'BlockBlob'},
      contentType: 'application/octet-stream',
      contentLength: await file.length(),
      body: file.openRead(),
    );
    if (response.statusCode != 201) {
      throw await _error('upload $key', response);
    }
    await response.drain<void>();
    await file.delete();
  }

  @override
  Future<String> downloadUrl(
    String key, {
    required Uri origin,
    required Duration ttl,
  }) async {
    final expiry = _sasTime(DateTime.now().toUtc().add(ttl));
    final sas = {
      'sv': apiVersion,
      'sr': 'b',
      'sp': 'r',
      'se': expiry,
      'sig': _sign(
        [
          'r', // signedPermissions
          '', // signedStart
          expiry,
          '/blob/${config.accountName}/${config.container}/$key',
          '', // signedIdentifier
          '', // signedIP
          '', // signedProtocol: https and http (Azurite)
          apiVersion,
          'b', // signedResource
          '', // signedSnapshotTime
          '', // signedEncryptionScope
          '', '', '', '', '', // rscc, rscd, rsce, rscl, rsct
        ].join('\n'),
      ),
    };
    return _blobUri(
      config.publicEndpoint ?? config.endpoint,
      key,
    ).replace(queryParameters: sas).toString();
  }

  @override
  Future<void> deletePrefix(String prefix) async {
    String? marker;
    do {
      final response = await _send(
        'GET',
        _containerUri({
          'restype': 'container',
          'comp': 'list',
          'prefix': prefix,
          'marker': ?marker,
        }),
      );
      if (response.statusCode != 200) {
        throw await _error('list $prefix', response);
      }
      final page = await utf8.decodeStream(response);
      final names = _blobNames
          .allMatches(page)
          .map((m) => _unescapeXml(m[1]!))
          .toList();
      for (var i = 0; i < names.length; i += _deleteConcurrency) {
        await Future.wait(names.skip(i).take(_deleteConcurrency).map(_delete));
      }
      final next = _nextMarker.firstMatch(page)?[1];
      marker = next == null || next.isEmpty ? null : _unescapeXml(next);
    } while (marker != null);
  }

  Future<void> _delete(String key) async {
    final response = await _send('DELETE', _blobUri(config.endpoint, key));
    // 404: already gone (e.g. a concurrent delete).
    if (response.statusCode != 202 && response.statusCode != 404) {
      throw await _error('delete $key', response);
    }
    await response.drain<void>();
  }

  Uri _containerUri(Map<String, String> query) => config.endpoint.replace(
    pathSegments: [..._base(config.endpoint), config.container],
    queryParameters: query,
  );

  Uri _blobUri(Uri endpoint, String key) => endpoint.replace(
    pathSegments: [..._base(endpoint), config.container, ...key.split('/')],
  );

  /// The endpoint's own path: empty for Azure, the account for Azurite.
  static List<String> _base(Uri endpoint) =>
      endpoint.pathSegments.where((s) => s.isNotEmpty).toList();

  /// Sends a request signed with the account key ("Shared Key"
  /// authorization, https://learn.microsoft.com/rest/api/storageservices/authorize-with-shared-key).
  Future<HttpClientResponse> _send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    String? contentType,
    int? contentLength,
    Stream<List<int>>? body,
  }) async {
    final msHeaders = {
      ...headers,
      'x-ms-date': HttpDate.format(DateTime.now()),
      'x-ms-version': apiVersion,
    };
    final canonicalHeaders =
        (msHeaders.keys.map((k) => k.toLowerCase()).toList()..sort())
            .map((k) => '$k:${msHeaders[k]!.trim()}\n')
            .join();
    final query = uri.queryParameters.keys.map((k) => k.toLowerCase()).toList()
      ..sort();
    final canonicalResource = StringBuffer('/${config.accountName}${uri.path}');
    for (final name in query) {
      canonicalResource.write('\n$name:${uri.queryParameters[name]}');
    }
    final stringToSign = [
      method,
      '', // Content-Encoding
      '', // Content-Language
      contentLength == null || contentLength == 0 ? '' : '$contentLength',
      '', // Content-MD5
      contentType ?? '',
      '', // Date (x-ms-date is used)
      '', // If-Modified-Since
      '', // If-Match
      '', // If-None-Match
      '', // If-Unmodified-Since
      '', // Range
      '$canonicalHeaders$canonicalResource',
    ].join('\n');

    final request = await _client.openUrl(method, uri);
    msHeaders.forEach(request.headers.set);
    request.headers.set(
      'authorization',
      'SharedKey ${config.accountName}:${_sign(stringToSign)}',
    );
    if (contentType != null) request.headers.set('content-type', contentType);
    if (contentLength != null) request.contentLength = contentLength;
    if (body != null) await request.addStream(body);
    return request.close();
  }

  String _sign(String stringToSign) => base64.encode(
    crypto.Hmac(crypto.sha256, _key).convert(utf8.encode(stringToSign)).bytes,
  );

  static Future<StorageException> _error(
    String action,
    HttpClientResponse response,
  ) async {
    final code = response.headers.value('x-ms-error-code');
    final body = await utf8.decodeStream(response).catchError((_) => '');
    return StorageException(
      'Azure Blob Storage: $action failed with ${response.statusCode}'
      '${code == null ? '' : ' $code'}',
      body,
    );
  }

  /// `yyyy-MM-ddTHH:mm:ssZ`, the form SAS times take.
  static String _sasTime(DateTime utc) =>
      '${utc.toIso8601String().substring(0, 19)}Z';

  static final _blobNames = RegExp(r'<Blob>\s*<Name>([^<]*)</Name>');
  static final _nextMarker = RegExp(r'<NextMarker>([^<]*)</NextMarker>');

  static String _unescapeXml(String s) => s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');
}
