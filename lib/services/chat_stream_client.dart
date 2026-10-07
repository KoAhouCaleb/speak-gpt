import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// A single streamed delta.
class Delta {
  const Delta({this.content, this.reasoning});

  final String? content;
  final String? reasoning;
}

class ApiException implements Exception {
  ApiException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Streaming chat completion client that keeps reasoning output.
///
/// Reasoning is returned by OpenAI-compatible servers (DeepSeek, vLLM, llama.cpp, Ollama,
/// OpenRouter, LM Studio...) under different field names, so every known name is read.
class ChatStreamClient {
  static const _reasoningKeys = [
    'reasoning_content',
    'reasoning',
    'reasoning_text',
    'thinking',
  ];

  /// Streams a chat completion. Close [client] to abort the request.
  static Stream<Delta> stream({
    required http.Client client,
    required String host,
    required String apiKey,
    required Map<String, dynamic> body,
  }) async* {
    final request =
        http.Request(
            'POST',
            Uri.parse(
              '${host.replaceAll(RegExp(r'/+$'), '')}/chat/completions',
            ),
          )
          ..headers.addAll({
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
            'Accept': 'text/event-stream',
          })
          ..body = jsonEncode({...body, 'stream': true});

    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 30));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final text = await response.stream.bytesToString();
      throw ApiException('HTTP ${response.statusCode}: $text');
    }

    final lines = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    await for (final line in lines) {
      if (!line.startsWith('data:')) continue;
      final data = line.substring(5).trim();
      if (data == '[DONE]') break;
      if (data.isEmpty) continue;

      final delta = parseChunk(data);
      if (delta != null) yield delta;
    }
  }

  /// Parses one SSE data payload. Returns null for chunks without text.
  static Delta? parseChunk(String data) {
    final dynamic chunk;
    try {
      chunk = jsonDecode(data);
    } catch (_) {
      return null;
    }
    if (chunk is! Map) return null;

    final error = chunk['error'];
    if (error != null) throw ApiException(jsonEncode(error));

    final choices = chunk['choices'];
    if (choices is! List || choices.isEmpty) return null;
    final first = choices[0];
    final delta = first is Map ? first['delta'] : null;
    if (delta is! Map) return null;

    final content = delta['content'] is String
        ? delta['content'] as String
        : null;
    String? reasoning;
    for (final key in _reasoningKeys) {
      final value = delta[key];
      if (value is String && value.isNotEmpty) {
        reasoning = value;
        break;
      }
    }

    if ((content == null || content.isEmpty) &&
        (reasoning == null || reasoning.isEmpty)) {
      return null;
    }
    return Delta(content: content, reasoning: reasoning);
  }

  /// Some servers put reasoning inline in content wrapped in `<think>...</think>`.
  /// Splits accumulated content into (reasoning, visible answer).
  static (String, String) splitThinkTags(String raw) {
    const openTag = '<think>';
    const closeTag = '</think>';
    final trimmed = raw.trimLeft();

    // Opening tag is still arriving
    if (trimmed.isNotEmpty && openTag.startsWith(trimmed)) return ('', '');

    if (!trimmed.startsWith(openTag)) {
      // Some models (QwQ, DeepSeek R1 distills) omit the opening tag
      final closeIndex = raw.indexOf(closeTag);
      if (closeIndex != -1 && !raw.substring(0, closeIndex).contains(openTag)) {
        return (
          raw.substring(0, closeIndex).trim(),
          raw.substring(closeIndex + closeTag.length).trimLeft(),
        );
      }
      return ('', raw);
    }

    final inner = trimmed.substring(openTag.length);
    final closeIndex = inner.indexOf(closeTag);

    if (closeIndex == -1) {
      // Hide a closing tag that is still arriving (for example "</th")
      var reasoning = inner;
      final max = closeTag.length - 1 < reasoning.length
          ? closeTag.length - 1
          : reasoning.length;
      for (var length = max; length >= 1; length--) {
        if (reasoning.endsWith(closeTag.substring(0, length))) {
          reasoning = reasoning.substring(0, reasoning.length - length);
          break;
        }
      }
      return (reasoning.trim(), '');
    }

    return (
      inner.substring(0, closeIndex).trim(),
      inner.substring(closeIndex + closeTag.length).trimLeft(),
    );
  }
}
