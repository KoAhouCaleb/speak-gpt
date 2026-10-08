import 'package:url_launcher/url_launcher.dart';

import '../models/models.dart';
import 'image_client.dart';
import 'native_bridge.dart';
import 'qr_reader.dart';
import 'searxng_client.dart';
import 'storage.dart';

enum ToolMode {
  disabled,
  confirm,
  auto;

  static ToolMode? parse(String? value) {
    for (final m in values) {
      if (m.name == value) return m;
    }
    return null;
  }
}

class ToolResult {
  const ToolResult(this.text, {this.imagePath});

  /// Text sent back to the model.
  final String text;

  /// Image produced by the tool, shown in the chat.
  final String? imagePath;
}

/// Everything a tool needs from the app. Replaceable in tests.
class ToolContext {
  ToolContext({
    required this.storage,
    required this.chatSettings,
    Future<bool> Function(Uri uri)? launch,
  }) : launch =
           launch ??
           ((uri) => launchUrl(uri, mode: LaunchMode.externalApplication));

  final Storage storage;
  final ChatSettings chatSettings;
  final Future<bool> Function(Uri uri) launch;
}

class AssistantTool {
  const AssistantTool({
    required this.name,
    required this.description,
    required this.properties,
    required this.required,
    required this.defaultMode,
    required this.describeCall,
    required this.run,
  });

  final String name;
  final String description;

  /// JSON schema "properties" object.
  final Map<String, Map<String, dynamic>> properties;
  final List<String> required;
  final ToolMode defaultMode;

  /// One line shown in the confirmation dialog.
  final String Function(Map<String, dynamic> args) describeCall;
  final Future<ToolResult> Function(Map<String, dynamic> args, ToolContext ctx)
  run;

  Map<String, dynamic> toRequestJson() => {
    'type': 'function',
    'function': {
      'name': name,
      'description': description,
      'parameters': {
        'type': 'object',
        'properties': properties,
        'required': required,
      },
    },
  };

  ToolMode mode(Storage storage) =>
      ToolMode.parse(storage.toolMode(name)) ?? defaultMode;
}

Map<String, dynamic> _str(String description, {List<String>? values}) => {
  'type': 'string',
  'description': description,
  if (values != null) 'enum': values,
};

String _arg(Map<String, dynamic> args, String key) {
  final v = args[key];
  if (v is String && v.trim().isNotEmpty) return v.trim();
  throw Exception('Missing argument "$key"');
}

String? _optArg(Map<String, dynamic> args, String key) {
  final v = args[key];
  return v is String && v.trim().isNotEmpty ? v.trim() : null;
}

Future<ToolResult> _open(ToolContext ctx, Uri uri, String success) async {
  final ok = await ctx.launch(uri);
  return ToolResult(
    ok ? success : 'Could not open ${uri.scheme} link, no app can handle it.',
  );
}

const _travelModes = {
  'driving': 'driving',
  'walking': 'walking',
  'bicycling': 'bicycling',
  'transit': 'transit',
};

Uri mapsDirections(String destination, String mode, List<String> stops) {
  return Uri.https('www.google.com', '/maps/dir/', {
    'api': '1',
    'destination': destination,
    'travelmode': _travelModes[mode] ?? 'driving',
    if (stops.isNotEmpty) 'waypoints': stops.join('|'),
  });
}

Uri musicSearch(String query, {String? type, String? artist}) {
  final q = [query, if (artist != null && type != 'artist') artist].join(' ');
  return Uri.https('music.youtube.com', '/search', {'q': q});
}

final List<AssistantTool> allTools = [
  AssistantTool(
    name: 'get_datetime',
    description:
        'Get the current local date, time and time zone of the device.',
    properties: const {},
    required: const [],
    defaultMode: ToolMode.auto,
    describeCall: (_) => 'Read the current date and time',
    run: (args, ctx) async {
      final now = DateTime.now();
      return ToolResult(
        '${now.toIso8601String()} (${now.timeZoneName}, UTC${now.timeZoneOffset.isNegative ? '-' : '+'}'
        '${now.timeZoneOffset.inHours.abs().toString().padLeft(2, '0')}:'
        '${(now.timeZoneOffset.inMinutes.abs() % 60).toString().padLeft(2, '0')})',
      );
    },
  ),
  AssistantTool(
    name: 'read_screen',
    description:
        'Read the text that was on the screen when the user opened the assistant. '
        'Only available if the user invoked the assistant from another app.',
    properties: const {},
    required: const [],
    defaultMode: ToolMode.confirm,
    describeCall: (_) =>
        'Read the text of the screen captured when you opened the assistant',
    run: (args, ctx) async {
      final captured = await NativeBridge.lastAssist();
      if (captured == null || captured.text.trim().isEmpty) {
        return const ToolResult(
          'No screen text is available. The user must open the assistant from the screen they want read, '
          'and allow the assistant to use screen text in the system settings.',
        );
      }
      return ToolResult(captured.text);
    },
  ),
  AssistantTool(
    name: 'read_qr_code',
    description:
        'Find QR codes on the screen the user was looking at when they opened the assistant and return the text they contain.',
    properties: const {},
    required: const [],
    defaultMode: ToolMode.confirm,
    describeCall: (_) => 'Look for QR codes on the captured screen',
    run: (args, ctx) async {
      final captured = await NativeBridge.lastAssist();
      if (captured == null || captured.screenshotPath.isEmpty) {
        return const ToolResult(
          'No screenshot is available. The user must open the assistant from the screen with the QR code, '
          'and allow the assistant to use the screenshot in the system settings.',
        );
      }
      final codes = await QrReader.readFile(captured.screenshotPath);
      if (codes.isEmpty) {
        return const ToolResult('No QR code was found on the screen.');
      }
      return ToolResult(
        [for (var i = 0; i < codes.length; i++) 'QR code ${i + 1}: ${codes[i]}']
            .join('\n'),
      );
    },
  ),
  AssistantTool(
    name: 'list_apps',
    description: 'List the apps installed on the device.',
    properties: const {},
    required: const [],
    defaultMode: ToolMode.confirm,
    describeCall: (_) => 'List installed apps',
    run: (args, ctx) async {
      final apps = await NativeBridge.listApps();
      if (apps.isEmpty) {
        return const ToolResult('The app list is not available.');
      }
      return ToolResult(
        apps.map((a) => '${a.label} (${a.package})').join('\n'),
      );
    },
  ),
  AssistantTool(
    name: 'open_app',
    description: 'Open an installed app.',
    properties: {
      'name': _str('App name as shown in the launcher, or its package name'),
    },
    required: const ['name'],
    defaultMode: ToolMode.confirm,
    describeCall: (a) => 'Open the app "${a['name']}"',
    run: (args, ctx) async {
      final name = _arg(args, 'name');
      final opened = await NativeBridge.openApp(name);
      return ToolResult(
        opened == null
            ? 'No installed app matches "$name".'
            : 'Opened $opened.',
      );
    },
  ),
  AssistantTool(
    name: 'start_navigation',
    description:
        'Start turn-by-turn navigation to a destination in the maps app.',
    properties: {
      'destination': _str('Address or place name'),
      'mode': _str(
        'Travel mode, driving by default',
        values: _travelModes.keys.toList(),
      ),
    },
    required: const ['destination'],
    defaultMode: ToolMode.confirm,
    describeCall: (a) => 'Navigate to "${a['destination']}"',
    run: (args, ctx) async {
      final destination = _arg(args, 'destination');
      final mode = _optArg(args, 'mode') ?? 'driving';
      await ctx.storage.setNavigation(destination, mode, const []);
      return _open(
        ctx,
        mapsDirections(destination, mode, const []),
        'Navigation to $destination started.',
      );
    },
  ),
  AssistantTool(
    name: 'add_navigation_stop',
    description:
        'Add a stop to the navigation that was started earlier, keeping the same destination.',
    properties: {
      'stop': _str('Address or place name of the stop'),
      'destination': _str(
        'Final destination, only needed if no navigation was started before',
      ),
    },
    required: const ['stop'],
    defaultMode: ToolMode.confirm,
    describeCall: (a) => 'Add the stop "${a['stop']}" to the navigation',
    run: (args, ctx) async {
      final stop = _arg(args, 'stop');
      final current = ctx.storage.navigation;
      final destination = current?.destination ?? _optArg(args, 'destination');
      if (destination == null) {
        return const ToolResult(
          'There is no navigation to add a stop to. Ask the user for the final destination.',
        );
      }
      final mode = current?.mode ?? 'driving';
      final stops = [...?current?.stops, stop];
      await ctx.storage.setNavigation(destination, mode, stops);
      return _open(
        ctx,
        mapsDirections(destination, mode, stops),
        'Navigation to $destination with ${stops.length} stop(s) started.',
      );
    },
  ),
  AssistantTool(
    name: 'play_music',
    description: 'Search for music in the music app and open the results.',
    properties: {
      'query': _str('Song, album, playlist or artist name'),
      'type': _str(
        'What the query is',
        values: const ['song', 'album', 'playlist', 'artist'],
      ),
      'artist': _str('Artist, to narrow down a song or an album'),
    },
    required: const ['query'],
    defaultMode: ToolMode.confirm,
    describeCall: (a) => 'Play "${a['query']}"',
    run: (args, ctx) async {
      final uri = musicSearch(
        _arg(args, 'query'),
        type: _optArg(args, 'type'),
        artist: _optArg(args, 'artist'),
      );
      return _open(ctx, uri, 'Opened the music search for "${args['query']}".');
    },
  ),
  AssistantTool(
    name: 'make_call',
    description:
        'Open the phone dialer with the number of a contact. The user presses the call button.',
    properties: {'contact': _str('Contact name or a phone number')},
    required: const ['contact'],
    defaultMode: ToolMode.confirm,
    describeCall: (a) => 'Call "${a['contact']}"',
    run: (args, ctx) async {
      final number = await _resolveNumber(_arg(args, 'contact'));
      if (number == null) {
        return ToolResult('No contact matches "${args['contact']}".');
      }
      return _open(
        ctx,
        Uri(scheme: 'tel', path: number.$2),
        'Dialer opened for ${number.$1}.',
      );
    },
  ),
  AssistantTool(
    name: 'send_text',
    description:
        'Send a text message (SMS) to a contact or phone number. It is sent right away.',
    properties: {
      'contact': _str('Contact name or a phone number'),
      'message': _str('Text of the message'),
    },
    required: const ['contact', 'message'],
    defaultMode: ToolMode.confirm,
    describeCall: (a) => 'Send a text to "${a['contact']}": ${a['message']}',
    run: (args, ctx) async {
      final number = await _resolveNumber(_arg(args, 'contact'));
      if (number == null) {
        return ToolResult('No contact matches "${args['contact']}".');
      }
      final message = _arg(args, 'message');
      try {
        await NativeBridge.sendSms(number.$2, message);
        return ToolResult('Text message sent to ${number.$1} (${number.$2}).');
      } catch (e) {
        // No permission or no telephony: let the user send it from the messaging app
        final opened = await ctx.launch(
          Uri(
            scheme: 'sms',
            path: number.$2,
            queryParameters: {'body': message},
          ),
        );
        return ToolResult(
          opened
              ? 'The text could not be sent directly (${_reason(e)}). The messaging app was opened with the message prepared, the user presses send.'
              : 'The text could not be sent: ${_reason(e)}.',
        );
      }
    },
  ),
  AssistantTool(
    name: 'open_webpage',
    description: 'Open a web page in the browser.',
    properties: {'url': _str('Full URL starting with http:// or https://')},
    required: const ['url'],
    defaultMode: ToolMode.confirm,
    describeCall: (a) => 'Open ${a['url']}',
    run: (args, ctx) async {
      final uri = Uri.tryParse(_arg(args, 'url'));
      if (uri == null ||
          (uri.scheme != 'http' && uri.scheme != 'https') ||
          uri.host.isEmpty) {
        return const ToolResult(
          'The URL is not valid. It must start with http:// or https://.',
        );
      }
      return _open(ctx, uri, 'Opened ${uri.host}.');
    },
  ),
  AssistantTool(
    name: 'web_search',
    description:
        'Open a web search in the browser for the user to read. To get results for yourself use search_internet.',
    properties: {'query': _str('Search query')},
    required: const ['query'],
    defaultMode: ToolMode.confirm,
    describeCall: (a) => 'Search the web for "${a['query']}" in the browser',
    run: (args, ctx) async {
      final uri = Uri.https('www.google.com', '/search', {
        'q': _arg(args, 'query'),
      });
      return _open(ctx, uri, 'Search opened in the browser.');
    },
  ),
  AssistantTool(
    name: 'search_internet',
    description:
        'Search the internet and get the results back as text. Use it for current events and facts you are unsure about.',
    properties: {'query': _str('Search query')},
    required: const ['query'],
    defaultMode: ToolMode.auto,
    describeCall: (a) => 'Search the internet for "${a['query']}"',
    run: (args, ctx) async {
      final url = ctx.storage.searxngUrl;
      if (url.isEmpty) {
        return const ToolResult(
          'Internet search is not set up. The user must enter a SearXNG instance URL in the tool settings.',
        );
      }
      return ToolResult(await SearxngClient.search(url, _arg(args, 'query')));
    },
  ),
  AssistantTool(
    name: 'generate_image',
    description:
        'Generate an image from a text description and show it to the user.',
    properties: {'prompt': _str('Detailed description of the image')},
    required: const ['prompt'],
    defaultMode: ToolMode.confirm,
    describeCall: (a) => 'Generate an image: ${a['prompt']}',
    run: (args, ctx) async {
      final endpoint = ctx.storage.endpointById(ctx.chatSettings.endpointId);
      if (endpoint == null || endpoint.apiKey.isEmpty) {
        return const ToolResult('No API key is set for this chat.');
      }
      final path = await ImageClient.generate(
        host: endpoint.host,
        apiKey: endpoint.apiKey,
        model: ctx.storage.imageModel,
        prompt: _arg(args, 'prompt'),
        size: ctx.storage.imageResolution,
      );
      return ToolResult(
        'The image was generated and is shown to the user.',
        imagePath: path,
      );
    },
  ),
  AssistantTool(
    name: 'list_calendar_events',
    description:
        'List the events in the calendar between two moments, 7 days from now by default.',
    properties: {
      'from': _str('Start, like 2026-10-08T00:00, defaults to now'),
      'to': _str('End, like 2026-10-15T00:00, defaults to a week after "from"'),
    },
    required: const [],
    defaultMode: ToolMode.confirm,
    describeCall: (a) => 'Read the calendar',
    run: (args, ctx) async {
      final from = _optDateArg(args, 'from') ?? DateTime.now();
      final to = _optDateArg(args, 'to') ?? from.add(const Duration(days: 7));
      final events = await NativeBridge.calendarEvents(from, to);
      if (events.isEmpty) {
        return ToolResult(
          'No events between ${formatMoment(from)} and ${formatMoment(to)}.',
        );
      }
      return ToolResult(events.map(describeEvent).join('\n'));
    },
  ),
  AssistantTool(
    name: 'add_calendar_event',
    description: 'Add an event to the calendar.',
    properties: {
      'title': _str('Title of the event'),
      'start': _str(
        'Start in local time, like 2026-10-08T15:00. For an all day event only the date matters.',
      ),
      'end': _str(
        'End in local time. Defaults to one hour after the start, or to the same day for an all day event. For an all day event this is the last day.',
      ),
      'all_day': {
        'type': 'boolean',
        'description': 'True for an all day event',
      },
      'location': _str('Where the event takes place'),
      'description': _str('Notes for the event'),
      'reminder_minutes': {
        'type': 'integer',
        'description': 'Reminder this many minutes before the start',
      },
    },
    required: const ['title', 'start'],
    defaultMode: ToolMode.confirm,
    describeCall: (a) => 'Add "${a['title']}" to the calendar at ${a['start']}',
    run: (args, ctx) async {
      final title = _arg(args, 'title');
      final allDay = args['all_day'] == true;
      var start = _dateArg(args, 'start');
      var end = _optDateArg(args, 'end');
      if (allDay) {
        final first = DateTime.utc(start.year, start.month, start.day);
        final last = end ?? start;
        // The end of an all day event is the midnight after its last day
        start = first;
        end = DateTime.utc(last.year, last.month, last.day + 1);
      } else {
        end ??= start.add(const Duration(hours: 1));
        if (!end.isAfter(start)) {
          return const ToolResult('The end must be after the start.');
        }
      }
      final id = await NativeBridge.calendarAdd(
        title: title,
        start: start,
        end: end,
        allDay: allDay,
        location: _optArg(args, 'location'),
        description: _optArg(args, 'description'),
        reminderMinutes: _optIntArg(args, 'reminder_minutes'),
      );
      if (id == null) {
        return const ToolResult(
          'There is no calendar on the device that can be written to.',
        );
      }
      return ToolResult('Added "$title" to the calendar, event id $id.');
    },
  ),
  AssistantTool(
    name: 'update_calendar_event',
    description:
        'Change an event of the calendar. Only the given fields change. Get the id from list_calendar_events.',
    properties: {
      'id': {'type': 'integer', 'description': 'Event id'},
      'title': _str('New title'),
      'start': _str('New start in local time, like 2026-10-08T15:00'),
      'end': _str('New end in local time'),
      'location': _str('New location'),
      'description': _str('New notes'),
    },
    required: const ['id'],
    defaultMode: ToolMode.confirm,
    describeCall: (a) => 'Change calendar event ${a['id']}',
    run: (args, ctx) async {
      final id = _intArg(args, 'id');
      final ok = await NativeBridge.calendarUpdate(
        id,
        title: _optArg(args, 'title'),
        start: _optDateArg(args, 'start'),
        end: _optDateArg(args, 'end'),
        location: _optArg(args, 'location'),
        description: _optArg(args, 'description'),
      );
      return ToolResult(
        ok ? 'Event $id updated.' : 'No event with id $id was found.',
      );
    },
  ),
  AssistantTool(
    name: 'delete_calendar_event',
    description:
        'Delete an event from the calendar. Get the id from list_calendar_events.',
    properties: {
      'id': {'type': 'integer', 'description': 'Event id'},
    },
    required: const ['id'],
    defaultMode: ToolMode.confirm,
    describeCall: (a) => 'Delete calendar event ${a['id']}',
    run: (args, ctx) async {
      final id = _intArg(args, 'id');
      final ok = await NativeBridge.calendarDelete(id);
      return ToolResult(
        ok ? 'Event $id deleted.' : 'No event with id $id was found.',
      );
    },
  ),
  AssistantTool(
    name: 'set_alarm',
    description:
        'Set an alarm in the clock app. The time is on a 24 hour clock. Without days it rings once, at the next time that matches.',
    properties: {
      'time': _str('Time of day on a 24 hour clock, like 07:30'),
      'label': _str('Name of the alarm'),
      'days': {
        'type': 'array',
        'description': 'Weekdays to repeat on, empty for a single alarm',
        'items': {'type': 'string', 'enum': _weekdays.keys.toList()},
      },
    },
    required: const ['time'],
    defaultMode: ToolMode.confirm,
    describeCall: (a) => 'Set an alarm for ${a['time']}',
    run: (args, ctx) async {
      final clock = parseClock(_arg(args, 'time'));
      if (clock == null) {
        return const ToolResult(
          'The time must look like 07:30 (24 hour clock).',
        );
      }
      final days = parseWeekdays(args['days']);
      final ok = await NativeBridge.setAlarm(
        clock.$1,
        clock.$2,
        label: _optArg(args, 'label'),
        days: days,
      );
      return ToolResult(
        ok
            ? 'Alarm set for ${_two(clock.$1)}:${_two(clock.$2)}${days.isEmpty ? '' : ' (repeating)'}.'
            : 'No clock app on the device accepted the alarm.',
      );
    },
  ),
  AssistantTool(
    name: 'set_timer',
    description: 'Start a countdown timer in the clock app.',
    properties: {
      'seconds': {'type': 'integer', 'description': 'Length in seconds'},
      'label': _str('Name of the timer'),
    },
    required: const ['seconds'],
    defaultMode: ToolMode.confirm,
    describeCall: (a) => 'Start a timer for ${a['seconds']} seconds',
    run: (args, ctx) async {
      final seconds = _intArg(args, 'seconds');
      if (seconds < 1 || seconds > 86400) {
        return const ToolResult(
          'The timer must be between 1 second and 24 hours.',
        );
      }
      final ok = await NativeBridge.setTimer(
        seconds,
        label: _optArg(args, 'label'),
      );
      return ToolResult(
        ok
            ? 'Timer started for $seconds seconds.'
            : 'No clock app on the device accepted the timer.',
      );
    },
  ),
  AssistantTool(
    name: 'delete_alarm',
    description:
        'Delete alarms in the clock app by time or by label, or all of them when neither is given. '
        'Android has no way to list alarms, so the result only says the request was passed on.',
    properties: {
      'time': _str('Time of day of the alarm on a 24 hour clock, like 07:30'),
      'label': _str('Name of the alarm'),
    },
    required: const [],
    defaultMode: ToolMode.confirm,
    describeCall: (a) {
      if (a['time'] != null) return 'Delete the alarm at ${a['time']}';
      if (a['label'] != null) return 'Delete the alarm "${a['label']}"';
      return 'Delete all alarms';
    },
    run: (args, ctx) async {
      final time = _optArg(args, 'time');
      final clock = time == null ? null : parseClock(time);
      if (time != null && clock == null) {
        return const ToolResult(
          'The time must look like 07:30 (24 hour clock).',
        );
      }
      final ok = await NativeBridge.dismissAlarm(
        hour: clock?.$1,
        minute: clock?.$2,
        label: _optArg(args, 'label'),
      );
      return ToolResult(
        ok
            ? 'The request to delete the alarm was passed to the clock app. It cannot confirm whether one matched.'
            : 'The clock app on the device does not support deleting alarms.',
      );
    },
  ),
  AssistantTool(
    name: 'show_alarms',
    description:
        'Open the alarm list in the clock app so the user can see them. Alarms cannot be read by the assistant.',
    properties: const {},
    required: const [],
    defaultMode: ToolMode.confirm,
    describeCall: (_) => 'Open the alarm list',
    run: (args, ctx) async {
      final ok = await NativeBridge.showAlarms();
      return ToolResult(
        ok ? 'The alarm list was opened.' : 'No clock app was found.',
      );
    },
  ),
  AssistantTool(
    name: 'list_todos',
    description:
        'List the tasks of the to-do list kept inside this app. Done tasks are left out unless asked for.',
    properties: {
      'include_done': {
        'type': 'boolean',
        'description': 'Also list the tasks that are done',
      },
    },
    required: const [],
    defaultMode: ToolMode.auto,
    describeCall: (_) => 'Read the to-do list',
    run: (args, ctx) async {
      final includeDone = args['include_done'] == true;
      final items = ctx.storage.todos
          .where((t) => includeDone || !t.done)
          .toList();
      if (items.isEmpty) return const ToolResult('The to-do list is empty.');
      return ToolResult(items.map(describeTodo).join('\n'));
    },
  ),
  AssistantTool(
    name: 'add_todo',
    description: 'Add a task to the to-do list kept inside this app.',
    properties: {
      'title': _str('What has to be done'),
      'due': _str(
        'Optional due date or moment in local time, like 2026-10-08 or 2026-10-08T15:00',
      ),
      'notes': _str('Optional details'),
    },
    required: const ['title'],
    defaultMode: ToolMode.auto,
    describeCall: (a) => 'Add the task "${a['title']}"',
    run: (args, ctx) async {
      final title = _arg(args, 'title');
      final item = TodoItem(
        id: DateTime.now().microsecondsSinceEpoch.toRadixString(36),
        title: title,
        notes: _optArg(args, 'notes') ?? '',
        due: _optDateArg(args, 'due'),
      );
      await ctx.storage.saveTodo(item);
      return ToolResult('Added the task: ${describeTodo(item)}');
    },
  ),
  AssistantTool(
    name: 'update_todo',
    description:
        'Change a task, or mark it done or not done. Find it by id or by its title.',
    properties: {
      'id': _str('Task id from list_todos'),
      'title': _str('Current title, if the id is not known'),
      'new_title': _str('New title'),
      'due': _str('New due date or moment in local time, "none" removes it'),
      'notes': _str('New details'),
      'done': {
        'type': 'boolean',
        'description': 'True when the task is finished',
      },
    },
    required: const [],
    defaultMode: ToolMode.auto,
    describeCall: (a) => 'Change the task "${a['title'] ?? a['id']}"',
    run: (args, ctx) async {
      final item = findTodo(ctx.storage, args);
      final newTitle = _optArg(args, 'new_title');
      if (newTitle != null) item.title = newTitle;
      final notes = _optArg(args, 'notes');
      if (notes != null) item.notes = notes;
      final due = _optArg(args, 'due');
      if (due != null) {
        item.due = due.toLowerCase() == 'none' ? null : _dateArg(args, 'due');
      }
      if (args['done'] is bool) item.done = args['done'] as bool;
      await ctx.storage.saveTodo(item);
      return ToolResult('Updated: ${describeTodo(item)}');
    },
  ),
  AssistantTool(
    name: 'delete_todo',
    description:
        'Remove a task from the to-do list. Find it by id or by its title.',
    properties: {
      'id': _str('Task id from list_todos'),
      'title': _str('Title, if the id is not known'),
    },
    required: const [],
    defaultMode: ToolMode.confirm,
    describeCall: (a) => 'Delete the task "${a['title'] ?? a['id']}"',
    run: (args, ctx) async {
      final item = findTodo(ctx.storage, args);
      await ctx.storage.deleteTodo(item.id);
      return ToolResult('Deleted the task "${item.title}".');
    },
  ),
];

String _reason(Object e) => e.toString().replaceFirst('Exception: ', '');

/// Parses "2026-10-08T15:00", "2026-10-08 15:00" or "2026-10-08" as local time.
DateTime? parseLocalDateTime(String? value) {
  if (value == null) return null;
  final parsed = DateTime.tryParse(value.trim());
  if (parsed == null) return null;
  return parsed.isUtc ? parsed.toLocal() : parsed;
}

DateTime _dateArg(Map<String, dynamic> args, String key) {
  final value = parseLocalDateTime(_arg(args, key));
  if (value == null) {
    throw Exception(
      '"$key" is not a date. Use the format 2026-10-08T15:00 in local time.',
    );
  }
  return value;
}

DateTime? _optDateArg(Map<String, dynamic> args, String key) =>
    _optArg(args, key) == null ? null : _dateArg(args, key);

int _intArg(Map<String, dynamic> args, String key) {
  final v = args[key];
  final n = v is num ? v.toInt() : int.tryParse('$v'.trim());
  if (n == null) throw Exception('Missing number "$key"');
  return n;
}

int? _optIntArg(Map<String, dynamic> args, String key) =>
    args[key] == null ? null : _intArg(args, key);

String _two(int n) => n.toString().padLeft(2, '0');

String formatDay(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

String formatMoment(DateTime d) =>
    '${formatDay(d)}T${_two(d.hour)}:${_two(d.minute)}';

String describeEvent(CalendarEvent e) {
  final when = e.allDay
      ? 'all day ${formatDay(e.start)}${e.end.difference(e.start).inDays > 1 ? ' to ${formatDay(e.end.subtract(const Duration(days: 1)))}' : ''}'
      : '${formatMoment(e.start)} to ${formatMoment(e.end)}';
  return '[${e.id}] ${e.title} ($when)'
      '${e.location.isEmpty ? '' : ', at ${e.location}'}'
      '${e.description.isEmpty ? '' : ', notes: ${e.description}'}';
}

/// Parses "07:30" or "7:30" (24 hour clock).
(int, int)? parseClock(String value) {
  final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(value.trim());
  if (m == null) return null;
  final h = int.parse(m.group(1)!);
  final min = int.parse(m.group(2)!);
  if (h > 23 || min > 59) return null;
  return (h, min);
}

/// Android's Calendar numbering: 1 is Sunday.
const _weekdays = {
  'sunday': 1,
  'monday': 2,
  'tuesday': 3,
  'wednesday': 4,
  'thursday': 5,
  'friday': 6,
  'saturday': 7,
};

List<int> parseWeekdays(Object? value) {
  if (value is! List) return const [];
  final days = <int>{};
  for (final v in value) {
    final day = _weekdays['$v'.trim().toLowerCase()];
    if (day == null) throw Exception('"$v" is not a day of the week');
    days.add(day);
  }
  return days.toList()..sort();
}

String describeTodo(TodoItem t) =>
    '[${t.id}] ${t.done ? '(done) ' : ''}${t.title}'
    '${t.due == null ? '' : ' (due ${formatMoment(t.due!)})'}'
    '${t.notes.isEmpty ? '' : ', notes: ${t.notes}'}';

/// Finds a to-do by id, else by title (exact, then partial). Throws if the title is ambiguous.
TodoItem findTodo(Storage storage, Map<String, dynamic> args) {
  final all = storage.todos;
  final id = _optArg(args, 'id');
  if (id != null) {
    for (final t in all) {
      if (t.id == id) return t;
    }
  }
  final query = (_optArg(args, 'title') ?? id ?? '').toLowerCase();
  if (query.isEmpty) throw Exception('Give the id or the title of the task');

  final exact = all.where((t) => t.title.toLowerCase() == query).toList();
  final matches = exact.isNotEmpty
      ? exact
      : all.where((t) => t.title.toLowerCase().contains(query)).toList();
  if (matches.isEmpty) throw Exception('No task matches "$query"');
  if (matches.length > 1) {
    throw Exception(
      'Several tasks match "$query", use the id: ${matches.map(describeTodo).join('; ')}',
    );
  }
  return matches.single;
}

AssistantTool? toolByName(String name) {
  for (final t in allTools) {
    if (t.name == name) return t;
  }
  return null;
}

/// A bare phone number is used as is, anything else is looked up in the contacts.
Future<(String, String)?> _resolveNumber(String contact) async {
  if (RegExp(r'^\+?[\d\s\-().]{3,}$').hasMatch(contact)) {
    return (contact, contact.replaceAll(RegExp(r'[\s\-().]'), ''));
  }
  return NativeBridge.findContact(contact);
}
