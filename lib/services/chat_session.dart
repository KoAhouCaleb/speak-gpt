import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/models.dart';
import 'app_http.dart';
import 'chat_stream_client.dart';
import 'image_client.dart';
import 'storage.dart';
import 'tools.dart';

typedef ToolConfirm =
    Future<bool> Function(AssistantTool tool, Map<String, dynamic> args);

/// State and generation logic for one open chat.
class ChatSession extends ChangeNotifier {
  ChatSession(
    this.storage,
    this.chatId, {
    ToolContext? toolContext,
    http.Client Function()? clientFactory,
  }) : messages = storage.messages(chatId),
       _clientFactory = clientFactory ?? AppHttp.newClient {
    _toolContext = toolContext;
  }

  /// Most tool rounds before the model is forced to answer in text.
  static const maxToolRounds = 6;

  final Storage storage;
  final String chatId;
  final List<ChatMessage> messages;

  /// Asks the user whether a tool may run. Without it, tools in confirm mode are refused.
  ToolConfirm? confirmTool;

  /// Called with the final answer text, used for speech output.
  void Function(String text)? onAnswer;

  /// Whether an answer is read aloud: after a dictated message unless silent mode is on,
  /// and always in "always speak" mode, which wins over silent mode. Typed messages are only
  /// answered aloud in "always speak" mode.
  static bool shouldSpeak({
    required bool fromVoice,
    required bool silent,
    required bool alwaysSpeak,
  }) => (fromVoice && !silent) || alwaysSpeak;

  bool _lastFromVoice = false;

  bool generating = false;
  String? error;
  http.Client? _client;
  bool _disposed = false;
  bool _stopRequested = false;
  ToolContext? _toolContext;
  final http.Client Function() _clientFactory;

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

  static bool isReasoningModel(String model) =>
      model.contains('gpt-5') || model.contains('o1') || model.contains('o3');

  /// Builds the chat message list in the API format.
  List<Map<String, dynamic>> buildMessages(
    ChatSettings s,
    List<ChatMessage> history,
  ) {
    final result = <Map<String, dynamic>>[];
    if (s.systemMessage.trim().isNotEmpty) {
      result.add({'role': 'system', 'content': s.systemMessage});
    }

    for (final m in history) {
      if (m.isBot) {
        // Answers that are only a picture or only a tool log carry nothing for the model
        if (m.text.trim().isNotEmpty) {
          result.add({'role': 'assistant', 'content': m.text});
        }
        continue;
      }

      final text = '${s.prefix}${_userText(m)}${s.endSeparator}';
      if (m.imagePath.isNotEmpty && File(m.imagePath).existsSync()) {
        final bytes = base64Encode(File(m.imagePath).readAsBytesSync());
        result.add({
          'role': 'user',
          'content': [
            if (text.isNotEmpty) {'type': 'text', 'text': text},
            {
              'type': 'image_url',
              'image_url': {'url': 'data:${_mime(m.imagePath)};base64,$bytes'},
            },
          ],
        });
      } else {
        result.add({'role': 'user', 'content': text});
      }
    }
    return result;
  }

  /// The user's words, preceded by the screen text when one was attached.
  static String _userText(ChatMessage m) {
    if (m.contextText.trim().isEmpty) return m.text;
    return 'This is the text currently on my screen:\n```\n${m.contextText.trim()}\n```\n\n${m.text}'
        .trim();
  }

  static String _mime(String path) {
    final p = path.toLowerCase();
    if (p.endsWith('.png')) return 'image/png';
    if (p.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }

  /// Builds the request body. Defaults are omitted so servers use their own.
  Map<String, dynamic> buildRequest(
    ChatSettings s,
    List<Map<String, dynamic>> apiMessages, {
    List<AssistantTool> tools = const [],
  }) {
    final model = s.model;
    // Reasoning models only accept the default temperature
    final reasoning = isReasoningModel(model);
    final body = <String, dynamic>{'model': model, 'messages': apiMessages};

    if (reasoning) {
      body['temperature'] = 1.0;
    } else if (s.temperature != 0.7) {
      body['temperature'] = s.temperature;
    }
    if (s.topP != 1.0) body['top_p'] = s.topP;
    if (s.frequencyPenalty != 0.0) {
      body['frequency_penalty'] = s.frequencyPenalty;
    }
    if (s.presencePenalty != 0.0) body['presence_penalty'] = s.presencePenalty;
    if (s.maxTokens > 0 && !reasoning) body['max_tokens'] = s.maxTokens;
    final seed = int.tryParse(s.seed);
    if (seed != null) body['seed'] = seed;

    final bias = s.logitBiasSetId.isEmpty
        ? null
        : storage.logitBiasSetById(s.logitBiasSetId);
    if (bias != null && bias.biases.isNotEmpty && !reasoning) {
      body['logit_bias'] = bias.biases;
    }

    if (tools.isNotEmpty) {
      body['tools'] = tools.map((t) => t.toRequestJson()).toList();
      body['tool_choice'] = 'auto';
    }
    return body;
  }

  /// Tools that may be offered to the model in this chat.
  List<AssistantTool> activeTools(ChatSettings s) {
    if (!s.functionCalling) return const [];
    return allTools.where((t) => t.mode(storage) != ToolMode.disabled).toList();
  }

  /// Sends a user message. `/imagine <prompt>` generates an image instead.
  Future<void> send(
    String text, {
    String imagePath = '',
    String contextText = '',
    bool fromVoice = false,
  }) async {
    final trimmed = text.trim();
    if ((trimmed.isEmpty && imagePath.isEmpty && contextText.isEmpty) ||
        generating) {
      return;
    }
    messages.add(
      ChatMessage(
        text: trimmed,
        isBot: false,
        imagePath: imagePath,
        contextText: contextText,
      ),
    );

    _lastFromVoice = fromVoice;

    if (imagePath.isEmpty &&
        settings.imagineCommand &&
        trimmed.toLowerCase().startsWith('/imagine ')) {
      await _imagine(trimmed.substring(9).trim());
    } else {
      await _generate();
    }
  }

  /// Drops the last answer (if any) and asks again.
  Future<void> regenerate() async {
    if (generating) return;
    while (messages.isNotEmpty && messages.last.isBot) {
      messages.removeLast();
    }
    if (messages.isEmpty) return;
    _lastFromVoice = false;
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

  ApiEndpoint? _endpointOrError(ChatSettings s) {
    final endpoint = storage.endpointById(s.endpointId);
    if (endpoint == null || endpoint.apiKey.isEmpty) {
      error =
          'No API key is set for the selected endpoint. Add one in Settings > API endpoints.';
      return null;
    }
    return endpoint;
  }

  Future<void> _imagine(String prompt) async {
    final s = settings;
    error = null;
    _stopRequested = false;
    final endpoint = _endpointOrError(s);
    if (endpoint == null || prompt.isEmpty) {
      if (prompt.isEmpty) error = 'Write a description after /imagine.';
      await storage.saveMessages(chatId, messages);
      _notify();
      return;
    }

    final answer = ChatMessage(text: '', isBot: true);
    messages.add(answer);
    generating = true;
    _notify();

    final client = _clientFactory();
    _client = client;
    try {
      answer.imagePath = await ImageClient.generate(
        host: endpoint.host,
        apiKey: endpoint.apiKey,
        model: storage.imageModel,
        prompt: prompt,
        size: storage.imageResolution,
        client: client,
      );
      answer.text = prompt;
    } catch (e) {
      if (_stopRequested) {
        messages.remove(answer);
      } else if (storage.showChatErrors) {
        answer.errorText = e.toString();
      } else {
        error = e.toString();
        messages.remove(answer);
      }
    } finally {
      client.close();
      _client = null;
      generating = false;
      await storage.saveMessages(chatId, messages);
      await storage.touchChat(chatId);
      _notify();
    }
  }

  Future<void> _generate() async {
    final s = settings;
    error = null;
    _stopRequested = false;

    final endpoint = _endpointOrError(s);
    if (endpoint == null) {
      await storage.saveMessages(chatId, messages);
      _notify();
      return;
    }

    final apiMessages = buildMessages(s, List<ChatMessage>.of(messages));
    final answer = ChatMessage(text: '', isBot: true);
    messages.add(answer);
    generating = true;
    _notify();

    final client = _clientFactory();
    _client = client;
    final tools = activeTools(s);
    final toolContext =
        _toolContext ?? ToolContext(storage: storage, chatSettings: s);

    try {
      var finished = '';
      for (var round = 0; round <= maxToolRounds; round++) {
        var raw = '';
        var rawReasoning = '';
        final calls = ToolCallAccumulator();

        // The last round has no tools so the model has to answer
        final stream = ChatStreamClient.stream(
          client: client,
          host: endpoint.host,
          apiKey: endpoint.apiKey,
          body: buildRequest(
            s,
            apiMessages,
            tools: round < maxToolRounds ? tools : const [],
          ),
        );

        await for (final delta in stream) {
          if (delta.reasoning != null) rawReasoning += delta.reasoning!;
          if (delta.content != null) raw += delta.content!;
          calls.add(delta.toolCalls);

          final (inlineReasoning, visible) = ChatStreamClient.splitThinkTags(
            raw,
          );
          answer.reasoning = [
            rawReasoning,
            inlineReasoning,
          ].where((e) => e.isNotEmpty).join('\n\n');
          answer.text = finished + visible;
          _notify();
        }

        if (calls.isEmpty) break;

        final toolCalls = calls.build();
        final (_, visible) = ChatStreamClient.splitThinkTags(raw);
        if (visible.isNotEmpty) finished += '$visible\n\n';
        apiMessages.add({
          'role': 'assistant',
          'content': visible.isEmpty ? null : visible,
          'tool_calls': toolCalls.map((c) => c.toJson()).toList(),
        });

        for (final call in toolCalls) {
          final result = await _runTool(call, toolContext, answer);
          apiMessages.add({
            'role': 'tool',
            'tool_call_id': call.id,
            'content': result,
          });
          _notify();
          if (_stopRequested) break;
        }
        if (_stopRequested) break;
      }
    } catch (e) {
      // Closing the client on purpose (stop button) also surfaces as an exception
      if (!_stopRequested) {
        // Inside the chat the error is saved with the answer. Otherwise it is only a banner.
        if (storage.showChatErrors) {
          answer.errorText = e.toString();
        } else {
          error = e.toString();
        }
      }
    } finally {
      client.close();
      _client = null;
      generating = false;
      final empty =
          answer.text.isEmpty &&
          answer.reasoning.isEmpty &&
          answer.imagePath.isEmpty &&
          answer.toolLog.isEmpty &&
          answer.errorText.isEmpty;
      if (empty) messages.remove(answer);
      await storage.saveMessages(chatId, messages);
      await storage.touchChat(chatId);
      final s = settings;
      if (!empty &&
          error == null &&
          answer.errorText.isEmpty &&
          answer.text.trim().isNotEmpty &&
          shouldSpeak(
            fromVoice: _lastFromVoice,
            silent: s.silentMode,
            alwaysSpeak: s.alwaysSpeak,
          )) {
        onAnswer?.call(answer.text);
      }
      _notify();
    }
  }

  Future<String> _runTool(
    ToolCall call,
    ToolContext ctx,
    ChatMessage answer,
  ) async {
    final tool = toolByName(call.name);
    if (tool == null) return 'Unknown tool "${call.name}".';

    final Map<String, dynamic> args;
    try {
      final decoded = jsonDecode(call.arguments);
      args = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (_) {
      return 'The arguments are not valid JSON.';
    }

    final mode = tool.mode(storage);
    if (mode == ToolMode.disabled) {
      return 'This tool is disabled by the user. Answer without it.';
    }

    if (mode == ToolMode.confirm) {
      final allowed = confirmTool == null
          ? false
          : await confirmTool!(tool, args);
      if (!allowed) {
        _log(answer, 'Declined: ${tool.describeCall(args)}');
        return 'The user declined this action. Do not try again, answer in text.';
      }
    }

    try {
      final result = await tool.run(args, ctx);
      _log(answer, tool.describeCall(args));
      if (result.imagePath != null) answer.imagePath = result.imagePath!;
      return result.text;
    } catch (e) {
      _log(answer, 'Failed: ${tool.describeCall(args)}');
      return 'The tool failed: $e';
    }
  }

  void _log(ChatMessage answer, String line) {
    answer.toolLog = answer.toolLog.isEmpty ? line : '${answer.toolLog}\n$line';
    _notify();
  }
}
