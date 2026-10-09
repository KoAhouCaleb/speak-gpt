import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import 'vad_params.dart';

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
    await _readKeys();
  }

  Future<void> _readKeys() async {
    for (final e in endpointsRaw) {
      _keys[e.id] = await _secure.read(key: 'endpoint_key_${e.id}') ?? '';
    }
    _supersyncToken = await _secure.read(key: 'supersync_token') ?? '';
    _supersyncPassword = await _secure.read(key: 'supersync_password') ?? '';
    for (final type in [speechStt, speechTts]) {
      _speechKeys[type] =
          await _secure.read(key: 'speech_server_key_$type') ?? '';
    }
  }

  /// Re-reads everything from disk. The assistant overlay runs in its own Flutter engine
  /// and writes chats there, so the main window must refresh when it comes back.
  Future<void> reload() async {
    await _prefs.reload();
    _keys.clear();
    await _readKeys();
    notifyListeners();
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

  /// Send a dictated message as soon as the recognizer finishes.
  bool get autoSend => _prefs.getBool('auto_send') ?? true;
  Future<void> setAutoSend(bool v) async {
    await _prefs.setBool('auto_send', v);
    notifyListeners();
  }

  /// Play a short chime in the assistant overlay when it starts listening.
  bool get readySound => _prefs.getBool('ready_sound') ?? true;
  Future<void> setReadySound(bool v) async {
    await _prefs.setBool('ready_sound', v);
    notifyListeners();
  }

  /// Show why an answer failed inside the chat. Off shows a message that disappears.
  bool get showChatErrors => _prefs.getBool('show_chat_errors') ?? true;
  Future<void> setShowChatErrors(bool v) async {
    await _prefs.setBool('show_chat_errors', v);
    notifyListeners();
  }

  // ---- Voice activity detection and wake word ------------------------

  /// Dictate button: end the message when the speaker stops talking.
  bool get vadOnDictate => _prefs.getBool('vad_on_dictate') ?? false;
  Future<void> setVadOnDictate(bool v) async {
    await _prefs.setBool('vad_on_dictate', v);
    notifyListeners();
  }

  /// Headset button long press: start listening with VAD as soon as Grace opens.
  bool get vadHeadset => _prefs.getBool('vad_headset') ?? false;
  Future<void> setVadHeadset(bool v) async {
    await _prefs.setBool('vad_headset', v);
    notifyListeners();
  }

  /// Assistant gesture: start listening with VAD as soon as Grace opens.
  bool get vadGesture => _prefs.getBool('vad_gesture') ?? false;
  Future<void> setVadGesture(bool v) async {
    await _prefs.setBool('vad_gesture', v);
    notifyListeners();
  }

  /// Wake word: listen with VAD after the wake word (otherwise the normal dictation starts).
  bool get vadWakeWord => _prefs.getBool('vad_wake_word') ?? false;
  Future<void> setVadWakeWord(bool v) async {
    await _prefs.setBool('vad_wake_word', v);
    notifyListeners();
  }

  /// Whether the VAD setting of the given trigger is on. Triggers are the strings the native
  /// side and the wake word service use: 'headset', 'gesture' and 'wakeword'. An empty or
  /// unknown trigger means the dictate button.
  bool vadForTrigger(String trigger) => switch (trigger) {
    'headset' => vadHeadset,
    'gesture' => vadGesture,
    'wakeword' => vadWakeWord,
    _ => vadOnDictate,
  };

  /// Listen for the wake word while the app is open.
  bool get wakeWordEnabled => _prefs.getBool('wake_word_enabled') ?? false;
  Future<void> setWakeWordEnabled(bool v) async {
    await _prefs.setBool('wake_word_enabled', v);
    notifyListeners();
  }

  // Advanced VAD settings, in frames of the Silero v5 model (32 ms each)
  int get vadMinSpeechFrames =>
      _prefs.getInt('vad_min_speech_frames') ??
      VadParams.defaults.minSpeechFrames;
  int get vadPreSpeechPadFrames =>
      _prefs.getInt('vad_pre_speech_pad_frames') ??
      VadParams.defaults.preSpeechPadFrames;
  int get vadRedemptionFrames =>
      _prefs.getInt('vad_redemption_frames') ??
      VadParams.defaults.redemptionFrames;
  double get vadPositiveThreshold =>
      _prefs.getDouble('vad_positive_threshold') ??
      VadParams.defaults.positiveSpeechThreshold;
  double get vadNegativeThreshold =>
      _prefs.getDouble('vad_negative_threshold') ??
      VadParams.defaults.negativeSpeechThreshold;

  VadParams get vadParams => VadParams(
    minSpeechFrames: vadMinSpeechFrames,
    preSpeechPadFrames: vadPreSpeechPadFrames,
    redemptionFrames: vadRedemptionFrames,
    positiveSpeechThreshold: vadPositiveThreshold,
    negativeSpeechThreshold: vadNegativeThreshold,
  );

  Future<void> setVadParams(VadParams p) async {
    await _prefs.setInt('vad_min_speech_frames', p.minSpeechFrames);
    await _prefs.setInt('vad_pre_speech_pad_frames', p.preSpeechPadFrames);
    await _prefs.setInt('vad_redemption_frames', p.redemptionFrames);
    await _prefs.setDouble('vad_positive_threshold', p.positiveSpeechThreshold);
    await _prefs.setDouble('vad_negative_threshold', p.negativeSpeechThreshold);
    notifyListeners();
  }

  /// Who reads answers aloud: 'device' (Android text to speech) or 'endpoint' (the
  /// /audio/speech route of the chat's API endpoint). A configured speech server wins over both.
  String get ttsEngine => _prefs.getString('tts_engine') ?? 'device';
  Future<void> setTtsEngine(String v) async {
    await _prefs.setString('tts_engine', v);
    notifyListeners();
  }

  String get ttsEndpointVoice =>
      _prefs.getString('tts_endpoint_voice') ?? 'alloy';
  Future<void> setTtsEndpointVoice(String v) async {
    await _prefs.setString('tts_endpoint_voice', v);
    notifyListeners();
  }

  /// Audio format asked from text to speech servers: mp3, wav or opus.
  String get ttsAudioFormat => _prefs.getString('tts_audio_format') ?? 'mp3';
  Future<void> setTtsAudioFormat(String v) async {
    await _prefs.setString('tts_audio_format', v);
    notifyListeners();
  }

  String get ttsEndpointModel =>
      _prefs.getString('tts_endpoint_model') ?? 'tts-1';
  Future<void> setTtsEndpointModel(String v) async {
    await _prefs.setString('tts_endpoint_model', v);
    notifyListeners();
  }

  /// Locale id for speech input and output, empty for the device default.
  String get speechLocale => _prefs.getString('speech_locale') ?? '';
  Future<void> setSpeechLocale(String v) async {
    await _prefs.setString('speech_locale', v);
    notifyListeners();
  }

  /// Open the assistant gesture as a compact sheet over the current app, not full screen.
  /// The native session reads this key too (flutter.assist_overlay).
  bool get assistOverlay => _prefs.getBool('assist_overlay') ?? true;
  Future<void> setAssistOverlay(bool v) async {
    await _prefs.setBool('assist_overlay', v);
    notifyListeners();
  }

  bool get autoAttachScreen => _prefs.getBool('auto_attach_screen') ?? true;
  Future<void> setAutoAttachScreen(bool v) async {
    await _prefs.setBool('auto_attach_screen', v);
    notifyListeners();
  }

  String get imageModel => _prefs.getString('image_model') ?? 'gpt-image-1';
  Future<void> setImageModel(String v) async {
    await _prefs.setString('image_model', v);
    notifyListeners();
  }

  String get imageResolution =>
      _prefs.getString('image_resolution') ?? '1024x1024';
  Future<void> setImageResolution(String v) async {
    await _prefs.setString('image_resolution', v);
    notifyListeners();
  }

  /// Base URL of the SearXNG instance used by the internet search tool.
  String get searxngUrl => _prefs.getString('searxng_url') ?? '';
  Future<void> setSearxngUrl(String v) async {
    await _prefs.setString('searxng_url', v.trim());
    notifyListeners();
  }

  /// Stored mode of a tool: 'disabled', 'confirm' or 'auto'. Null if never set.
  String? toolMode(String tool) => _prefs.getString('tool_mode_$tool');
  Future<void> setToolMode(String tool, String mode) async {
    await _prefs.setString('tool_mode_$tool', mode);
    notifyListeners();
  }

  /// Navigation started by the assistant, kept so a stop can be added later.
  ({String destination, String mode, List<String> stops})? get navigation {
    final raw = _prefs.getString('navigation');
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      // A trip older than 12 hours belongs to a previous journey
      if (DateTime.now().millisecondsSinceEpoch - (j['time'] as int) >
          12 * 3600 * 1000) {
        return null;
      }
      return (
        destination: j['destination'] as String,
        mode: j['mode'] as String,
        stops: List<String>.from(j['stops'] as List),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> setNavigation(
    String destination,
    String mode,
    List<String> stops,
  ) async {
    await _prefs.setString(
      'navigation',
      jsonEncode({
        'destination': destination,
        'mode': mode,
        'stops': stops,
        'time': DateTime.now().millisecondsSinceEpoch,
      }),
    );
  }

  // ---- Speech servers ------------------------------------------------------

  static const speechStt = 'stt';
  static const speechTts = 'tts';

  final Map<String, String> _speechKeys = {};

  /// Configuration of the self-hosted server for [type] ('stt' or 'tts').
  SpeechServerConfig speechServer(String type) {
    final raw = _prefs.getString('speech_server_$type');
    if (raw != null) {
      try {
        return SpeechServerConfig.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
          _speechKeys[type] ?? '',
        );
      } catch (_) {
        // Fall through to the defaults
      }
    }
    return SpeechServerConfig(
      apiKey: _speechKeys[type] ?? '',
      model: type == speechStt ? 'whisper-1' : 'kokoro',
    );
  }

  Future<void> saveSpeechServer(String type, SpeechServerConfig config) async {
    await _prefs.setString('speech_server_$type', jsonEncode(config.toJson()));
    _speechKeys[type] = config.apiKey;
    await _secure.write(key: 'speech_server_key_$type', value: config.apiKey);
    notifyListeners();
  }

  // ---- Logit bias sets ---------------------------------------------------

  List<LogitBiasSet> get logitBiasSets {
    final raw = _prefs.getString('logit_bias_sets');
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => LogitBiasSet.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveLogitBiasSet(LogitBiasSet set) async {
    final list = logitBiasSets.where((e) => e.id != set.id).toList()..add(set);
    await _prefs.setString(
      'logit_bias_sets',
      jsonEncode(list.map((e) => e.toJson()).toList()),
    );
    notifyListeners();
  }

  Future<void> deleteLogitBiasSet(String id) async {
    final list = logitBiasSets.where((e) => e.id != id).toList();
    await _prefs.setString(
      'logit_bias_sets',
      jsonEncode(list.map((e) => e.toJson()).toList()),
    );
    notifyListeners();
  }

  LogitBiasSet? logitBiasSetById(String id) {
    for (final s in logitBiasSets) {
      if (s.id == id) return s;
    }
    return null;
  }

  // ---- Prompts library -----------------------------------------------------

  List<SavedPrompt> get prompts {
    final raw = _prefs.getString('prompts');
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => SavedPrompt.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> savePrompt(SavedPrompt prompt) async {
    final all = prompts;
    final i = all.indexWhere((p) => p.id == prompt.id);
    if (i >= 0) {
      all[i] = prompt;
    } else {
      all.add(prompt);
    }
    await _prefs.setString(
      'prompts',
      jsonEncode(all.map((e) => e.toJson()).toList()),
    );
    notifyListeners();
  }

  Future<void> deletePrompt(String id) async {
    await _prefs.setString(
      'prompts',
      jsonEncode(
        prompts.where((p) => p.id != id).map((e) => e.toJson()).toList(),
      ),
    );
    notifyListeners();
  }

  // ---- Task server (Super Productivity SuperSync) ----------------------------

  String _supersyncToken = '';
  String _supersyncPassword = '';

  String get supersyncUrl => _prefs.getString('supersync_url') ?? '';
  String get supersyncToken => _supersyncToken;
  String get supersyncPassword => _supersyncPassword;
  String get supersyncCertificate =>
      _prefs.getString('supersync_certificate') ?? '';

  /// Identifies this app on the server. SuperSync allows letters, digits, underscore and hyphen.
  String get supersyncClientId {
    final existing = _prefs.getString('supersync_client_id');
    if (existing != null && existing.isNotEmpty) return existing;
    final r = Random.secure();
    final id =
        'Grace_${List.generate(10, (_) => r.nextInt(36).toRadixString(36)).join()}';
    unawaited(_prefs.setString('supersync_client_id', id));
    return id;
  }

  bool get supersyncConfigured =>
      supersyncUrl.isNotEmpty && supersyncToken.isNotEmpty;

  Future<void> saveSupersync({
    required String url,
    required String token,
    required String password,
    required String certificate,
  }) async {
    await _prefs.setString('supersync_url', url.trim());
    await _prefs.setString('supersync_certificate', certificate.trim());
    _supersyncToken = token.trim();
    await _secure.write(key: 'supersync_token', value: _supersyncToken);
    _supersyncPassword = password;
    await _secure.write(key: 'supersync_password', value: password);
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

  /// Settings copied into every new chat.
  ChatSettings get defaultChatSettings {
    final raw = _prefs.getString('default_chat_settings');
    final fallbackEndpoint = sha256Hex(_defaultEndpoint);
    try {
      if (raw != null) {
        final s = ChatSettings.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
        if (s.endpointId.isEmpty) s.endpointId = fallbackEndpoint;
        return s;
      }
    } catch (_) {
      // Fall through to the built-in defaults
    }
    return ChatSettings(endpointId: fallbackEndpoint);
  }

  Future<void> saveDefaultChatSettings(ChatSettings s) async {
    await _prefs.setString('default_chat_settings', jsonEncode(s.toJson()));
    notifyListeners();
  }

  Future<ChatInfo> addChat(String name, {ChatSettings? settings}) async {
    final info = ChatInfo(
      name: name,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
    await _saveChats([...chats, info]);
    await _prefs.setString('chat_${info.id}', '[]');
    await saveChatSettings(info.id, settings ?? defaultChatSettings);
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
