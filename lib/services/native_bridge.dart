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

/// Text and a picture shared into Grace from another app.
class ShareContent {
  const ShareContent({this.text = '', this.imagePath = ''});

  final String text;
  final String imagePath;

  factory ShareContent.fromMap(Map<dynamic, dynamic>? map) => ShareContent(
    text: '${map?['text'] ?? ''}',
    imagePath: '${map?['imagePath'] ?? ''}',
  );
}

class CalendarEvent {
  const CalendarEvent({
    required this.id,
    required this.title,
    required this.start,
    required this.end,
    required this.allDay,
    this.location = '',
    this.description = '',
    this.calendar = '',
  });

  final int id;
  final String title;
  final DateTime start;
  final DateTime end;
  final bool allDay;
  final String location;
  final String description;
  final String calendar;

  factory CalendarEvent.fromMap(Map<dynamic, dynamic> map) {
    final allDay = map['allDay'] == true;
    // All day events are stored as UTC midnights, show them as local dates
    DateTime read(Object? ms) {
      final utc = DateTime.fromMillisecondsSinceEpoch(
        (ms as num).toInt(),
        isUtc: true,
      );
      return allDay ? DateTime(utc.year, utc.month, utc.day) : utc.toLocal();
    }

    return CalendarEvent(
      id: (map['id'] as num).toInt(),
      title: '${map['title'] ?? ''}',
      start: read(map['start']),
      end: read(map['end']),
      allDay: allDay,
      location: '${map['location'] ?? ''}',
      description: '${map['description'] ?? ''}',
      calendar: '${map['calendar'] ?? ''}',
    );
  }
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
    void Function(ShareContent)? onShare,
  }) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onAssist') {
        onAssist?.call(AssistContext.fromMap(call.arguments as Map?));
      } else if (call.method == 'onOpenChat') {
        onOpenChat?.call('${call.arguments}');
      } else if (call.method == 'onShare') {
        onShare?.call(ShareContent.fromMap(call.arguments as Map?));
      }
      return null;
    });
  }

  /// Content that started the app through the share sheet, or null.
  static Future<ShareContent?> takePendingShare() async {
    try {
      final map = await _channel.invokeMethod<Map>('takePendingShare');
      return map == null ? null : ShareContent.fromMap(map);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Whether the clipboard holds a picture.
  static Future<bool> clipboardHasImage() async {
    try {
      return await _channel.invokeMethod<bool>('clipboardHasImage') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Copies the picture on the clipboard into the cache folder and returns its path.
  static Future<String?> clipboardImage() async {
    try {
      return await _channel.invokeMethod<String>('clipboardImage');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
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

  /// PEM text of the certificate authorities the user installed on the device.
  static Future<List<String>> userCertificates() async {
    try {
      final list = await _channel.invokeMethod<List>('userCertificates') ?? [];
      return list.whereType<String>().toList();
    } on PlatformException {
      return [];
    } on MissingPluginException {
      return [];
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

  static Future<T> _device<T>(
    String method,
    String what, [
    Map<String, dynamic>? args,
  ]) async {
    try {
      final value = await _channel.invokeMethod<T>(method, args);
      return value as T;
    } on PlatformException catch (e) {
      if (e.code == 'permission_denied') {
        throw Exception('$what permission was denied');
      }
      throw Exception(e.message ?? e.code);
    } on MissingPluginException {
      throw Exception('$what is not available on this device');
    }
  }

  /// Sends a text message from the device without opening the messaging app.
  static Future<void> sendSms(String number, String message) =>
      _device<Object?>('sendSms', 'Sending texts', {
        'number': number,
        'message': message,
      });

  static Future<List<CalendarEvent>> calendarEvents(
    DateTime from,
    DateTime to,
  ) async {
    final list = await _device<List?>('calendarEvents', 'Calendar', {
      'from': from.millisecondsSinceEpoch,
      'to': to.millisecondsSinceEpoch,
    });
    return [
      for (final e in (list ?? []).whereType<Map>()) CalendarEvent.fromMap(e),
    ];
  }

  /// Returns the id of the new event, or null if there is no calendar to write to.
  static Future<int?> calendarAdd({
    required String title,
    required DateTime start,
    required DateTime end,
    bool allDay = false,
    String? location,
    String? description,
    int? reminderMinutes,
    String? recurrenceRule,
  }) => _device<int?>('calendarAdd', 'Calendar', {
    'title': title,
    'start': start.millisecondsSinceEpoch,
    'end': end.millisecondsSinceEpoch,
    'allDay': allDay,
    'rrule': ?recurrenceRule,
    'location': ?location,
    'description': ?description,
    'reminderMinutes': ?reminderMinutes,
  });

  static Future<bool> calendarUpdate(
    int id, {
    String? title,
    DateTime? start,
    DateTime? end,
    String? location,
    String? description,
  }) async {
    final ok = await _device<bool?>('calendarUpdate', 'Calendar', {
      'id': id,
      'title': ?title,
      'start': ?start?.millisecondsSinceEpoch,
      'end': ?end?.millisecondsSinceEpoch,
      'location': ?location,
      'description': ?description,
    });
    return ok ?? false;
  }

  static Future<bool> calendarDelete(int id) async =>
      await _device<bool?>('calendarDelete', 'Calendar', {'id': id}) ?? false;

  /// [days] uses 1 for Sunday to 7 for Saturday, empty for a single alarm.
  static Future<bool> setAlarm(
    int hour,
    int minute, {
    String? label,
    List<int> days = const [],
  }) async =>
      await _device<bool?>('setAlarm', 'Alarm', {
        'hour': hour,
        'minute': minute,
        'label': ?label,
        'days': days,
      }) ??
      false;

  static Future<bool> setTimer(int seconds, {String? label}) async =>
      await _device<bool?>('setTimer', 'Timer', {
        'seconds': seconds,
        'label': ?label,
      }) ??
      false;

  static Future<bool> showAlarms() async =>
      await _device<bool?>('showAlarms', 'Alarm') ?? false;

  static Future<bool> dismissAlarm({
    int? hour,
    int? minute,
    String? label,
  }) async =>
      await _device<bool?>('dismissAlarm', 'Alarm', {
        'hour': ?hour,
        'minute': ?minute,
        'label': ?label,
      }) ??
      false;

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
