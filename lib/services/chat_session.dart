import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/models.dart';
import 'chat_stream_client.dart';
import 'storage.dart';

/// State and generation logic for one open chat.
class ChatSession extends ChangeNotifier {
  ChatSession(this.storage, this.chatId) : messages = storage.messages(chatId);

  final Storage storage;
  final String chatId;
  final List<ChatMessage> messages;

  bool generating = false;
  String? error;
  http.Client? _client;
  bool _disposed = false;
  bool _stopRequested = false;

  ChatSettings get settings => storage.chatSettings(chatId);

  @override
  void dispose() {
    _disposed = true;
    _client?.close();
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Builds the request body. Defaults are omitted so servers use their own.
  Map<String, dynamic> buildRequest(ChatSettings s, List<ChatMessage> history) {
    final model = s.model;
    // Reasoning models only accept the default temperature
    final fixedTemperature =
        model.contains('gpt-5') || model.contains('o1') || model.contains('o3');
    final body = <String, dynamic>{
      'model': model,
      'messages': [
        if (s.systemMessage.trim().isNotEmpty)
          {'role': 'system', 'content': s.systemMessage},
        for (final m in history)
          {'role': m.isBot ? 'assistant' : 'user', 'content': m.text},
      ],
    };
    if (fixedTemperature) {
      body['temperature'] = 1.0;
    } else if (s.temperature != 0.7) {
      body['temperature'] = s.temperature;
    }
    if (s.topP != 1.0) body['top_p'] = s.topP;
    if (s.frequencyPenalty != 0.0) {
      body['frequency_penalty'] = s.frequencyPenalty;
    }
    if (s.presencePenalty != 0.0) body['presence_penalty'] = s.presencePenalty;
    final seed = int.tryParse(s.seed);
    if (seed != null) body['seed'] = seed;
    return body;
  }

  Future<void> send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || generating) return;
    messages.add(ChatMessage(text: trimmed, isBot: false));
    await _generate();
  }

  /// Drops the last answer (if any) and asks again.
  Future<void> regenerate() async {
    if (generating) return;
    while (messages.isNotEmpty && messages.last.isBot) {
      messages.removeLast();
    }
    if (messages.isEmpty) return;
    await _generate();
  }

  Future<void> editMessage(int index, String text) async {
    messages[index].text = text;
    await storage.saveMessages(chatId, messages);
    _notify();
  }

  Future<void> deleteMessage(int index) async {
    messages.removeAt(index);
    await storage.saveMessages(chatId, messages);
    _notify();
  }

  Future<void> clear() async {
    stop();
    messages.clear();
    await storage.saveMessages(chatId, messages);
    _notify();
  }

  void stop() {
    _stopRequested = true;
    _client?.close();
  }

  Future<void> _generate() async {
    final s = settings;
    final endpoint = storage.endpointById(s.endpointId);
    error = null;
    _stopRequested = false;

    if (endpoint == null || endpoint.apiKey.isEmpty) {
      error =
          'No API key is set for the selected endpoint. Add one in Settings > API endpoints.';
      await storage.saveMessages(chatId, messages);
      _notify();
      return;
    }

    final history = List<ChatMessage>.of(messages);
    final answer = ChatMessage(text: '', isBot: true);
    messages.add(answer);
    generating = true;
    _notify();

    var raw = '';
    var rawReasoning = '';
    final client = http.Client();
    _client = client;

    try {
      final stream = ChatStreamClient.stream(
        client: client,
        host: endpoint.host,
        apiKey: endpoint.apiKey,
        body: buildRequest(s, history),
      );

      await for (final delta in stream) {
        if (delta.reasoning != null) rawReasoning += delta.reasoning!;
        if (delta.content != null) raw += delta.content!;

        final (inlineReasoning, visible) = ChatStreamClient.splitThinkTags(raw);
        answer.reasoning = [
          rawReasoning,
          inlineReasoning,
        ].where((e) => e.isNotEmpty).join('\n\n');
        answer.text = visible;
        _notify();
      }
    } catch (e) {
      // Closing the client on purpose (stop button) also surfaces as an exception
      if (!_stopRequested) error = e.toString();
    } finally {
      client.close();
      _client = null;
      generating = false;
      if (answer.text.isEmpty && answer.reasoning.isEmpty) {
        messages.remove(answer);
      }
      await storage.saveMessages(chatId, messages);
      await storage.touchChat(chatId);
      _notify();
    }
  }
}
