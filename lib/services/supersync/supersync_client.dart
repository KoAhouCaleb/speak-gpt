import 'dart:convert';

import 'package:http/http.dart' as http;

import '../app_http.dart';

class SuperSyncException implements Exception {
  SuperSyncException(this.message, {this.status});

  final String message;
  final int? status;

  @override
  String toString() => message;
}

/// HTTP access to a SuperSync server (the sync server of Super Productivity).
class SuperSyncClient {
  SuperSyncClient({
    required String url,
    required this.token,
    required this.clientId,
    String certificate = '',
    http.Client Function()? clientFactory,
  }) : _base = _normalize(url),
       _clientFactory =
           clientFactory ?? (() => AppHttp.newClient(extraPem: certificate));

  final Uri _base;
  final String token;
  final String clientId;
  final http.Client Function() _clientFactory;

  static Uri _normalize(String url) {
    var text = url.trim();
    if (text.isEmpty) throw SuperSyncException('No task server URL is set');
    if (!text.contains('://')) text = 'https://$text';
    while (text.endsWith('/')) {
      text = text.substring(0, text.length - 1);
    }
    return Uri.parse(text);
  }

  Uri _uri(String path, [Map<String, String>? query]) => _base.replace(
    path: '${_base.path}/api/sync/$path',
    queryParameters: query,
  );

  Future<Map<String, dynamic>> _send(
    String method,
    Uri uri, {
    Map<String, dynamic>? body,
  }) async {
    final client = _clientFactory();
    try {
      final request = http.Request(method, uri)
        ..headers['Authorization'] = 'Bearer $token'
        ..headers['Accept'] = 'application/json';
      if (body != null) {
        request.headers['Content-Type'] = 'application/json';
        request.body = jsonEncode(body);
      }
      final response = await http.Response.fromStream(
        await client.send(request).timeout(const Duration(seconds: 60)),
      );
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw SuperSyncException(
          'The task server refused the access token (${response.statusCode}). Copy a new one from Super Productivity.',
          status: response.statusCode,
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw SuperSyncException(
          'The task server answered ${response.statusCode}: ${_short(response.body)}',
          status: response.statusCode,
        );
      }
      final decoded = response.body.isEmpty ? {} : jsonDecode(response.body);
      return decoded is Map ? decoded.cast<String, dynamic>() : {};
    } on SuperSyncException {
      rethrow;
    } on FormatException {
      throw SuperSyncException('The task server did not answer with JSON');
    } catch (e) {
      throw SuperSyncException('Could not reach the task server: $e');
    } finally {
      client.close();
    }
  }

  static String _short(String body) =>
      body.length > 200 ? '${body.substring(0, 200)}...' : body;

  /// One page of operations after [sinceSeq].
  Future<Map<String, dynamic>> download(int sinceSeq, {int limit = 500}) =>
      _send('GET', _uri('ops', {'sinceSeq': '$sinceSeq', 'limit': '$limit'}));

  Future<Map<String, dynamic>> upload(List<Map<String, dynamic>> ops) =>
      _send('POST', _uri('ops'), body: {'ops': ops, 'clientId': clientId});

  Future<Map<String, dynamic>> status() => _send('GET', _uri('status'));
}
