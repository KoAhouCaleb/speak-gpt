import 'dart:convert';

import 'package:http/http.dart' as http;

import 'app_http.dart';

/// Fetches the model list from the /models endpoint of an OpenAI-compatible API.
class ModelListClient {
  static Future<List<String>> fetchModels(
    String host,
    String apiKey, {
    http.Client? client,
  }) async {
    final url = Uri.parse('${host.replaceAll(RegExp(r'/+$'), '')}/models');
    final c = client ?? AppHttp.newClient();
    final http.Response response;
    try {
      response = await c
          .get(url, headers: {'Authorization': 'Bearer $apiKey'})
          .timeout(const Duration(seconds: 30));
    } finally {
      if (client == null) c.close();
    }

    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}: ${response.body}');
    }

    final dynamic decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final data = decoded is Map ? decoded['data'] : decoded;
    if (data is! List) return [];

    final ids = <String>[];
    for (final item in data) {
      final id = item is Map ? item['id'] : item;
      if (id is String && id.isNotEmpty) ids.add(id);
    }
    ids.sort();
    return ids;
  }
}
