import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';

/// Persistence for chats, endpoints and settings. API keys live in secure storage.
class Storage extends ChangeNotifier {
  Storage(this._prefs, [FlutterSecureStorage? secure])
    : _secure = secure ?? const FlutterSecureStorage();

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secure;

  final Map<String, String> _keys = {};

  static const _defaultEndpoint = 'Default';

  static Future<Storage> open() async {
    final storage = Storage(await SharedPreferences.getInstance());
    await storage._load();
    return storage;
  }

  Future<void> _load() async {
    if (endpointsRaw.isEmpty) {
      await saveEndpoint(
        ApiEndpoint(
          label: _defaultEndpoint,
          host: 'https://api.openai.com/v1/',
        ),
      );
    }
    for (final e in endpointsRaw) {
      _keys[e.id] = await _secure.read(key: 'endpoint_key_${e.id}') ?? '';
    }
  }

  // ---- Global settings -------------------------------------------------

  bool get showReasoning => _prefs.getBool('show_reasoning') ?? true;
  Future<void> setShowReasoning(bool v) async {
    await _prefs.setBool('show_reasoning', v);
    notifyListeners();
  }

  /// 'system', 'light' or 'dark'
  String get themeMode => _prefs.getString('theme_mode') ?? 'system';
  Future<void> setThemeMode(String v) async {
    await _prefs.setString('theme_mode', v);
    notifyListeners();
  }

  bool get amoled => _prefs.getBool('amoled') ?? false;
  Future<void> setAmoled(bool v) async {
    await _prefs.setBool('amoled', v);
    notifyListeners();
  }

  // ---- Endpoints -------------------------------------------------------

  List<ApiEndpoint> get endpointsRaw {
    final raw = _prefs.getString('endpoints');
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => ApiEndpoint.fromJson(e as Map<String, dynamic>, ''))
          .toList();
    } catch (_) {
      return [];
    }
  }

  List<ApiEndpoint> get endpoints => endpointsRaw
      .map(
        (e) => ApiEndpoint(
          label: e.label,
          host: e.host,
          apiKey: _keys[e.id] ?? '',
        ),
      )
      .toList();

  ApiEndpoint? endpointById(String id) {
    for (final e in endpoints) {
      if (e.id == id) return e;
    }
    return null;
  }

  Future<void> saveEndpoint(ApiEndpoint endpoint) async {
    final list = endpointsRaw.where((e) => e.id != endpoint.id).toList()
      ..add(endpoint);
    await _prefs.setString(
      'endpoints',
      jsonEncode(list.map((e) => e.toJson()).toList()),
    );
    _keys[endpoint.id] = endpoint.apiKey;
    await _secure.write(
      key: 'endpoint_key_${endpoint.id}',
      value: endpoint.apiKey,
    );
    notifyListeners();
  }

  Future<void> deleteEndpoint(ApiEndpoint endpoint) async {
    final list = endpointsRaw.where((e) => e.id != endpoint.id).toList();
    await _prefs.setString(
      'endpoints',
      jsonEncode(list.map((e) => e.toJson()).toList()),
    );
    _keys.remove(endpoint.id);
    await _secure.delete(key: 'endpoint_key_${endpoint.id}');
    notifyListeners();
  }

  // ---- Chats -----------------------------------------------------------

  List<ChatInfo> get chats {
    final raw = _prefs.getString('chat_list');
    if (raw == null) return [];
    try {
      final list = (jsonDecode(raw) as List)
          .map((e) => ChatInfo.fromJson(e as Map<String, dynamic>))
          .toList();
      list.sort((a, b) {
        if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
        return b.timestamp.compareTo(a.timestamp);
      });
      return list;
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveChats(List<ChatInfo> list) async {
    await _prefs.setString(
      'chat_list',
      jsonEncode(list.map((c) => c.toJson()).toList()),
    );
    notifyListeners();
  }

  bool chatExists(String name) => chats.any((c) => c.name == name);

  /// Returns a chat name that is not used yet, such as "New chat 2".
  String availableChatName([String prefix = 'New chat']) {
    var x = 1;
    while (chatExists('$prefix $x')) {
      x++;
    }
    return '$prefix $x';
  }

  Future<ChatInfo> addChat(String name, {ChatSettings? settings}) async {
    final info = ChatInfo(
      name: name,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
    await _saveChats([...chats, info]);
    await _prefs.setString('chat_${info.id}', '[]');
    if (settings != null) await saveChatSettings(info.id, settings);
    return info;
  }

  Future<void> renameChat(ChatInfo chat, String newName) async {
    if (newName == chat.name) return;
    final messages = _prefs.getString('chat_${chat.id}') ?? '[]';
    final settings = _prefs.getString('chat_settings_${chat.id}');
    final renamed = chat.copyWith(name: newName);
    await _saveChats([...chats.where((c) => c.id != chat.id), renamed]);
    await _prefs.setString('chat_${renamed.id}', messages);
    if (settings != null) {
      await _prefs.setString('chat_settings_${renamed.id}', settings);
    }
    await _prefs.remove('chat_${chat.id}');
    await _prefs.remove('chat_settings_${chat.id}');
  }

  Future<void> deleteChat(ChatInfo chat) async {
    await _saveChats(chats.where((c) => c.id != chat.id).toList());
    await _prefs.remove('chat_${chat.id}');
    await _prefs.remove('chat_settings_${chat.id}');
  }

  Future<void> togglePin(ChatInfo chat) async {
    await _saveChats(
      chats
          .map((c) => c.id == chat.id ? c.copyWith(pinned: !c.pinned) : c)
          .toList(),
    );
  }

  Future<void> touchChat(String chatId) async {
    await _saveChats(
      chats
          .map(
            (c) => c.id == chatId
                ? c.copyWith(timestamp: DateTime.now().millisecondsSinceEpoch)
                : c,
          )
          .toList(),
    );
  }

  List<ChatMessage> messages(String chatId) {
    final raw = _prefs.getString('chat_$chatId');
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveMessages(String chatId, List<ChatMessage> messages) async {
    await _prefs.setString(
      'chat_$chatId',
      jsonEncode(messages.map((m) => m.toJson()).toList()),
    );
    notifyListeners();
  }

  ChatSettings chatSettings(String chatId) {
    final raw = _prefs.getString('chat_settings_$chatId');
    final fallbackEndpoint = sha256Hex(_defaultEndpoint);
    if (raw == null) return ChatSettings(endpointId: fallbackEndpoint);
    try {
      final s = ChatSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      if (s.endpointId.isEmpty) s.endpointId = fallbackEndpoint;
      return s;
    } catch (_) {
      return ChatSettings(endpointId: fallbackEndpoint);
    }
  }

  Future<void> saveChatSettings(String chatId, ChatSettings s) async {
    await _prefs.setString('chat_settings_$chatId', jsonEncode(s.toJson()));
  }
}
