import 'package:flutter/services.dart';

/// Screen content captured by the system when Grace is invoked as the digital assistant.
class AssistContext {
  const AssistContext({
    this.text = '',
    this.screenshotPath = '',
    this.timestamp = 0,
  });

  final String text;
  final String screenshotPath;
  final int timestamp;

  bool get isEmpty => text.trim().isEmpty && screenshotPath.isEmpty;

  factory AssistContext.fromMap(Map<dynamic, dynamic>? map) => AssistContext(
    text: '${map?['text'] ?? ''}',
    screenshotPath: '${map?['screenshotPath'] ?? ''}',
    timestamp: (map?['timestamp'] as num?)?.toInt() ?? 0,
  );
}

class InstalledApp {
  const InstalledApp({required this.label, required this.package});

  final String label;
  final String package;
}

/// Calls into the Android side (MainActivity.kt). Every method fails soft so that the
/// app keeps working on platforms that do not implement the channel.
class NativeBridge {
  NativeBridge._();

  static const _channel = MethodChannel('com.grace.assistant/native');

  /// Called when the system assistant gesture fires while the app is running, or when
  /// the assistant overlay asks to continue a chat in the main window.
  static void listen({
    void Function(AssistContext)? onAssist,
    void Function(String chatId)? onOpenChat,
  }) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onAssist') {
        onAssist?.call(AssistContext.fromMap(call.arguments as Map?));
      } else if (call.method == 'onOpenChat') {
        onOpenChat?.call('${call.arguments}');
      }
      return null;
    });
  }

  /// Chat the overlay handed over to a freshly started main window, or null.
  static Future<String?> takePendingChatId() async {
    try {
      return await _channel.invokeMethod<String>('takePendingChatId');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Opens the main window on a chat (from the overlay) and closes the overlay.
  /// With no chat id the main window just opens.
  static Future<void> openInMainWindow([String? chatId]) async {
    try {
      await _channel.invokeMethod<void>('openInMainWindow', {'chatId': chatId});
    } on PlatformException {
      // Nothing to do
    } on MissingPluginException {
      // Not Android
    }
  }

  /// Context captured for an assist launch that started the app, or null.
  static Future<AssistContext?> takePendingAssist() async {
    try {
      final map = await _channel.invokeMethod<Map>('takePendingAssist');
      return map == null ? null : AssistContext.fromMap(map);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Most recent capture, even if it was already shown. Null if none or too old.
  static Future<AssistContext?> lastAssist() async {
    try {
      final map = await _channel.invokeMethod<Map>('lastAssist');
      return map == null ? null : AssistContext.fromMap(map);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static Future<bool> isDefaultAssistant() async {
    try {
      return await _channel.invokeMethod<bool>('isDefaultAssistant') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<void> openAssistantSettings() async {
    try {
      await _channel.invokeMethod<void>('openAssistantSettings');
    } on PlatformException {
      // Nothing to do, the settings screen is not available on this device
    } on MissingPluginException {
      // Not Android
    }
  }

  static Future<List<InstalledApp>> listApps() async {
    try {
      final list = await _channel.invokeMethod<List>('listApps') ?? [];
      return [
        for (final e in list.whereType<Map>())
          InstalledApp(label: '${e['label']}', package: '${e['package']}'),
      ];
    } on PlatformException {
      return [];
    } on MissingPluginException {
      return [];
    }
  }

  /// Opens an app by label or package name. Returns the label that was opened, or null.
  static Future<String?> openApp(String name) async {
    try {
      return await _channel.invokeMethod<String>('openApp', {'name': name});
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Looks up a phone number by contact name. Asks for the contacts permission if needed.
  /// Returns (displayName, number), or null if nothing matched.
  static Future<(String, String)?> findContact(String name) async {
    try {
      final map = await _channel.invokeMethod<Map>('findContact', {
        'name': name,
      });
      if (map == null) return null;
      return ('${map['name']}', '${map['number']}');
    } on PlatformException catch (e) {
      if (e.code == 'permission_denied') {
        throw Exception('Contacts permission was denied');
      }
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
