import 'dart:convert';
import 'dart:io' show HeaderValue;

import 'package:http_parser/http_parser.dart';
import 'package:mime/mime.dart';
import 'package:shelf/shelf.dart';

import 'http.dart';

/// One part of a multipart/form-data body.
class FormPart {
  FormPart(this.name, this.filename, this.stream);
  final String name;
  final String? filename;
  final Stream<List<int>> stream;
}

MediaType? _mediaType(Request request) {
  final header = request.headers['content-type'];
  return header == null ? null : MediaType.parse(header);
}

bool isMultipart(Request request) =>
    _mediaType(request)?.mimeType == 'multipart/form-data';

/// Streams the parts of a multipart/form-data body. Each part's stream must
/// be consumed (or drained) before the next part arrives.
Stream<FormPart> multipartParts(Request request) {
  final boundary = _mediaType(request)?.parameters['boundary'];
  if (boundary == null) {
    throw ApiError.badRequest('multipart/form-data without a boundary.');
  }
  return request
      .read()
      .map<List<int>>((b) => b)
      .transform(MimeMultipartTransformer(boundary))
      .map((part) {
        final disposition = HeaderValue.parse(
          part.headers['content-disposition'] ?? '',
        );
        final name = disposition.parameters['name'];
        if (name == null) {
          throw ApiError.badRequest('Form part without a name.');
        }
        return FormPart(name, disposition.parameters['filename'], part);
      });
}

/// Reads a body sent either as JSON or as multipart/form-data text fields.
///
/// The CLI registers artifacts with multipart fields, which are always
/// strings on the wire, and sends an object field (`signing`) JSON-encoded.
/// [intFields], [boolFields] and [jsonFields] restore the JSON types the
/// protocol's `fromJson` expects.
Future<Map<String, dynamic>> readFormOrJson(
  Request request, {
  Set<String> intFields = const {},
  Set<String> boolFields = const {},
  Set<String> jsonFields = const {},
}) async {
  if (!isMultipart(request)) return readJsonObject(request);
  final fields = <String, dynamic>{};
  await for (final part in multipartParts(request)) {
    if (part.filename != null) {
      await part.stream.drain<void>();
      continue;
    }
    final value = await utf8.decodeStream(part.stream);
    if (intFields.contains(part.name)) {
      final parsed = int.tryParse(value);
      if (parsed == null) {
        throw ApiError.badRequest('${part.name} must be an integer.');
      }
      fields[part.name] = parsed;
    } else if (boolFields.contains(part.name)) {
      fields[part.name] = value == 'true';
    } else if (jsonFields.contains(part.name)) {
      try {
        fields[part.name] = jsonDecode(value);
      } on FormatException {
        throw ApiError.badRequest('${part.name} must be JSON.');
      }
    } else {
      fields[part.name] = value;
    }
  }
  return fields;
}
