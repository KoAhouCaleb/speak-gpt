import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/models.dart';
import 'app_http.dart';

/// Client for self-hosted OpenAI-compatible speech servers.
///
/// Known API shapes:
/// - Speech to text, for example hangrylabs/qwen3-asr-stt or faster-whisper-server:
///   POST /v1/audio/transcriptions (multipart: file, model, response_format, language).
/// - Text to speech, for example remsky/Kokoro-FastAPI:
///   POST /v1/audio/speech (json: model, input, voice, response_format),
///   GET /v1/audio/voices.
class SpeechServerClient {
  static Uri _url(String host, String path) =>
      Uri.parse('${host.trim().replaceAll(RegExp(r'/+$'), '')}/$path');

  static Map<String, String> _auth(SpeechServerConfig c) => {
    if (c.apiKey.trim().isNotEmpty)
      'Authorization': 'Bearer ${c.apiKey.trim()}',
  };

  /// Transcribes an audio file and returns the text.
  static Future<String> transcribe(
    SpeechServerConfig config,
    File audio, {
    http.Client? client,
  }) async {
    final request =
        http.MultipartRequest('POST', _url(config.host, 'audio/transcriptions'))
          ..headers.addAll(_auth(config))
          ..fields['response_format'] = 'json'
          ..files.add(await http.MultipartFile.fromPath('file', audio.path));
    if (config.model.trim().isNotEmpty) {
      request.fields['model'] = config.model.trim();
    }
    if (config.language.trim().isNotEmpty) {
      request.fields['language'] = config.language.trim();
    }

    final c = client ?? AppHttp.newClient();
    try {
      final response = await http.Response.fromStream(
        await c.send(request).timeout(const Duration(minutes: 2)),
      );
      final body = utf8.decode(response.bodyBytes);
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}: $body');
      }

      try {
        final json = jsonDecode(body);
        if (json is Map) return '${json['text'] ?? ''}'.trim();
      } on FormatException {
        // Servers asked for plain text answer with the text itself
      }
      return body.trim();
    } finally {
      if (client == null) c.close();
    }
  }

  /// Synthesizes speech and returns MP3 bytes.
  static Future<Uint8List> speak(
    SpeechServerConfig config,
    String text, {
    http.Client? client,
  }) async {
    final body = <String, dynamic>{
      'input': text,
      'voice': config.voice,
      'response_format': config.format,
    };
    if (config.model.trim().isNotEmpty) body['model'] = config.model.trim();

    final c = client ?? AppHttp.newClient();
    try {
      final response = await c
          .post(
            _url(config.host, 'audio/speech'),
            headers: {..._auth(config), 'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(minutes: 2));
      if (response.statusCode != 200) {
        throw Exception(
          'HTTP ${response.statusCode}: ${utf8.decode(response.bodyBytes, allowMalformed: true)}',
        );
      }
      return response.bodyBytes;
    } finally {
      if (client == null) c.close();
    }
  }

  /// Lists the voices of a text to speech server (Kokoro-FastAPI: GET /v1/audio/voices).
  static Future<List<String>> listVoices(
    SpeechServerConfig config, {
    http.Client? client,
  }) async {
    final c = client ?? AppHttp.newClient();
    try {
      final response = await c
          .get(_url(config.host, 'audio/voices'), headers: _auth(config))
          .timeout(const Duration(seconds: 30));
      final body = utf8.decode(response.bodyBytes);
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}: $body');
      }

      final json = jsonDecode(body);
      final list = json is List
          ? json
          : (json is Map && json['voices'] is List
                ? json['voices'] as List
                : const []);
      final voices = <String>[];
      for (final item in list) {
        // Older versions return plain strings, newer ones objects with an "id"
        final id = item is Map
            ? '${item['id'] ?? item['name'] ?? ''}'
            : '$item';
        if (id.isNotEmpty) voices.add(id);
      }
      return voices;
    } finally {
      if (client == null) c.close();
    }
  }
}
