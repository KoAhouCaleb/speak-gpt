import 'dart:convert';

import 'package:http/http.dart' as http;

/// Web search through a user-provided SearXNG instance.
///
/// Uses the JSON format of the search API (https://docs.searxng.org/dev/search_api.html),
/// which must be enabled in the instance's settings.yml (search.formats).
class SearxngClient {
  static const _maxSnippet = 400;

  static Future<String> search(
    String instanceUrl,
    String query, {
    int maxResults = 8,
    http.Client? client,
  }) async {
    var base = instanceUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (base.endsWith('/search')) base = base.substring(0, base.length - 7);
    final uri = Uri.tryParse(base);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw Exception('The SearXNG URL "$instanceUrl" is not valid');
    }

    final url = uri.replace(
      path: '${uri.path}/search',
      queryParameters: {'q': query, 'format': 'json'},
    );
    final c = client ?? http.Client();
    try {
      final response = await c
          .get(
            url,
            headers: {'Accept': 'application/json', 'User-Agent': 'Grace'},
          )
          .timeout(const Duration(seconds: 30));
      if (response.statusCode == 403) {
        throw Exception(
          'The SearXNG instance refused JSON results (HTTP 403). '
          'Enable the json format under search.formats in its settings.yml',
        );
      }
      if (response.statusCode != 200) {
        throw Exception('SearXNG returned HTTP ${response.statusCode}');
      }

      final dynamic root;
      try {
        root = jsonDecode(utf8.decode(response.bodyBytes));
      } catch (_) {
        throw Exception('SearXNG did not return JSON. Check the instance URL');
      }
      if (root is! Map) {
        throw Exception('SearXNG did not return JSON. Check the instance URL');
      }
      return format(root, maxResults);
    } finally {
      if (client == null) c.close();
    }
  }

  static String format(Map root, int maxResults) {
    final out = StringBuffer();

    // Direct answers (older versions return strings, newer ones objects with an "answer" field)
    final answers = <String>[];
    for (final a in (root['answers'] as List? ?? [])) {
      final text = a is Map ? _text(a['answer']) : _text(a);
      if (text != null) answers.add(text);
    }
    if (answers.isNotEmpty) {
      out.writeln('Answers:');
      for (final a in answers) {
        out.writeln('- $a');
      }
      out.writeln();
    }

    for (final box in (root['infoboxes'] as List? ?? []).whereType<Map>()) {
      final title = _text(box['infobox']);
      final content = _text(box['content']);
      if (title != null || content != null) {
        final body = content == null
            ? null
            : (content.length > _maxSnippet
                  ? content.substring(0, _maxSnippet)
                  : content);
        out.writeln(
          'Infobox: ${[title, body].whereType<String>().join(' - ')}\n',
        );
      }
    }

    final results = (root['results'] as List? ?? [])
        .whereType<Map>()
        .take(maxResults)
        .toList();
    if (results.isEmpty && out.isEmpty) return 'No results found.';

    for (var i = 0; i < results.length; i++) {
      final r = results[i];
      out.writeln('${i + 1}. ${_text(r['title']) ?? '(no title)'}');
      final url = _text(r['url']);
      if (url != null) out.writeln('   $url');
      final date = _text(r['publishedDate']);
      if (date != null) out.writeln('   Published: $date');
      final content = _text(r['content']);
      if (content != null) {
        final t = content.trim();
        out.writeln(
          '   ${t.length > _maxSnippet ? t.substring(0, _maxSnippet) : t}',
        );
      }
    }
    return out.toString().trim();
  }

  static String? _text(dynamic v) {
    if (v is! String) return null;
    return v.trim().isEmpty ? null : v;
  }
}
