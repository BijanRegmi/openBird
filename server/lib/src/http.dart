import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shorebird_code_push_protocol/shorebird_code_push_protocol.dart';

/// An error answered as Shorebird's `ErrorResponse` envelope, which both the
/// CLI and the updater parse for `{code, message}`.
class ApiError implements Exception {
  ApiError(this.status, this.code, this.message, {this.details});

  factory ApiError.badRequest(String message, {String code = 'bad_request'}) =>
      ApiError(400, code, message);
  factory ApiError.unauthorized([
    String message = 'Missing or invalid API key.',
  ]) => ApiError(401, 'unauthorized', message);
  factory ApiError.forbidden([
    String message = 'You do not have access to this resource.',
  ]) => ApiError(403, 'forbidden', message);
  factory ApiError.notFound(String what) =>
      ApiError(404, 'not_found', '$what not found.');
  factory ApiError.conflict(String message, {String code = 'conflict'}) =>
      ApiError(409, code, message);

  final int status;
  final String code;
  final String message;
  final String? details;

  Response toResponse() => jsonResponse(
    ErrorResponse(code: code, message: message, details: details).toJson(),
    status: status,
  );

  @override
  String toString() => 'ApiError($status $code: $message)';
}

const _jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

Response jsonResponse(Object? body, {int status = 200}) =>
    Response(status, body: jsonEncode(body), headers: _jsonHeaders);

Response noContent() => Response(204);

/// Reads a JSON object body. The CLI sends JSON without a JSON content type
/// (package:http's `post(body: String)` sends text/plain), so the content
/// type is not checked.
Future<Map<String, dynamic>> readJsonObject(Request request) async {
  final text = await request.readAsString(utf8);
  if (text.trim().isEmpty) return <String, dynamic>{};
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    throw ApiError.badRequest('Request body is not valid JSON.');
  }
  if (decoded is! Map<String, dynamic>) {
    throw ApiError.badRequest('Request body must be a JSON object.');
  }
  return decoded;
}

/// Parses [json] with a generated protocol `fromJson`, turning a shape
/// mismatch into a 400 rather than a 500.
T parseBody<T>(
  Map<String, dynamic> json,
  T Function(Map<String, dynamic>) fromJson,
) {
  try {
    return fromJson(json);
  } on Object catch (error) {
    throw ApiError.badRequest('Invalid request body: $error');
  }
}

int pathInt(Request request, String name) {
  final value = int.tryParse(request.params[name] ?? '');
  if (value == null) throw ApiError.notFound(name);
  return value;
}

String pathString(Request request, String name) {
  final value = request.params[name];
  if (value == null || value.isEmpty) throw ApiError.notFound(name);
  return value;
}

extension RequestParams on Request {
  Map<String, String> get params =>
      (context['shelf_router/params'] as Map<String, String>?) ?? const {};
}
