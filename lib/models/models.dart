import 'dart:convert';

import 'package:crypto/crypto.dart';

/// SHA-256 hex digest, used for chat and endpoint ids (same scheme as the Android app).
String sha256Hex(String input) => sha256.convert(utf8.encode(input)).toString();

class ApiEndpoint {
  ApiEndpoint({required this.label, required this.host, this.apiKey = ''});

  final String label;
  final String host;
  final String apiKey;

  String get id => sha256Hex(label);

  Map<String, String> toJson() => {'label': label, 'host': host};

  factory ApiEndpoint.fromJson(Map<String, dynamic> json, String apiKey) =>
      ApiEndpoint(
        label: json['label'] as String? ?? '',
        host: json['host'] as String? ?? '',
        apiKey: apiKey,
      );
}

class ChatInfo {
  ChatInfo({required this.name, required this.timestamp, this.pinned = false});

  final String name;
  final int timestamp;
  final bool pinned;

  String get id => sha256Hex(name);

  ChatInfo copyWith({String? name, int? timestamp, bool? pinned}) => ChatInfo(
    name: name ?? this.name,
    timestamp: timestamp ?? this.timestamp,
    pinned: pinned ?? this.pinned,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'timestamp': timestamp,
    'pinned': pinned,
  };

  factory ChatInfo.fromJson(Map<String, dynamic> json) => ChatInfo(
    name: json['name'] as String? ?? '',
    timestamp: int.tryParse('${json['timestamp']}') ?? 0,
    pinned: '${json['pinned']}' == 'true',
  );
}

class ChatMessage {
  ChatMessage({required this.text, required this.isBot, this.reasoning = ''});

  String text;
  final bool isBot;
  String reasoning;

  Map<String, dynamic> toJson() => {
    'message': text,
    'isBot': isBot,
    if (reasoning.isNotEmpty) 'reasoning': reasoning,
  };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    text: '${json['message'] ?? ''}',
    isBot: json['isBot'] == true,
    reasoning: '${json['reasoning'] ?? ''}',
  );
}

/// Per-chat generation settings.
class ChatSettings {
  ChatSettings({
    this.endpointId = '',
    this.model = 'gpt-4o',
    this.systemMessage = '',
    this.temperature = 0.7,
    this.topP = 1.0,
    this.frequencyPenalty = 0.0,
    this.presencePenalty = 0.0,
    this.maxTokens = 1500,
    this.seed = '',
    this.assistantName = 'Grace',
  });

  String endpointId;
  String model;
  String systemMessage;
  double temperature;
  double topP;
  double frequencyPenalty;
  double presencePenalty;
  int maxTokens;
  String seed;
  String assistantName;

  Map<String, dynamic> toJson() => {
    'endpointId': endpointId,
    'model': model,
    'systemMessage': systemMessage,
    'temperature': temperature,
    'topP': topP,
    'frequencyPenalty': frequencyPenalty,
    'presencePenalty': presencePenalty,
    'maxTokens': maxTokens,
    'seed': seed,
    'assistantName': assistantName,
  };

  factory ChatSettings.fromJson(Map<String, dynamic> json) {
    final d = ChatSettings();
    return ChatSettings(
      endpointId: json['endpointId'] as String? ?? d.endpointId,
      model: json['model'] as String? ?? d.model,
      systemMessage: json['systemMessage'] as String? ?? d.systemMessage,
      temperature: (json['temperature'] as num?)?.toDouble() ?? d.temperature,
      topP: (json['topP'] as num?)?.toDouble() ?? d.topP,
      frequencyPenalty:
          (json['frequencyPenalty'] as num?)?.toDouble() ?? d.frequencyPenalty,
      presencePenalty:
          (json['presencePenalty'] as num?)?.toDouble() ?? d.presencePenalty,
      maxTokens: (json['maxTokens'] as num?)?.toInt() ?? d.maxTokens,
      seed: json['seed'] as String? ?? d.seed,
      assistantName: json['assistantName'] as String? ?? d.assistantName,
    );
  }
}

/// A preset from assets/ai_sets.json.
class AiSet {
  AiSet({
    required this.name,
    required this.desc,
    required this.owner,
    required this.apiEndpoint,
    required this.apiEndpointName,
    required this.model,
    required this.suggestedChatName,
    required this.apiKeyUrl,
    required this.assistantName,
  });

  final String name;
  final String desc;
  final String owner;
  final String apiEndpoint;
  final String apiEndpointName;
  final String model;
  final String suggestedChatName;
  final String apiKeyUrl;
  final String assistantName;

  factory AiSet.fromJson(Map<String, dynamic> j) => AiSet(
    name: '${j['name'] ?? ''}',
    desc: '${j['desc'] ?? ''}',
    owner: '${j['owner'] ?? ''}',
    apiEndpoint: '${j['apiEndpoint'] ?? ''}',
    apiEndpointName: '${j['apiEndpointName'] ?? ''}',
    model: '${j['model'] ?? ''}',
    suggestedChatName: '${j['suggestedChatName'] ?? ''}',
    apiKeyUrl: '${j['apiKeyUrl'] ?? ''}',
    assistantName: '${j['assistantName'] ?? j['name'] ?? ''}',
  );
}
