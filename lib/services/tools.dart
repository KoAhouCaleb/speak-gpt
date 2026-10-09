import 'package:url_launcher/url_launcher.dart';

import '../models/models.dart';
import 'image_client.dart';
import 'native_bridge.dart';
import 'qr_reader.dart';
import 'searxng_client.dart';
import 'storage.dart';
import 'supersync/supersync_factory.dart';
import 'supersync/supersync_tasks.dart';

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
    Future<SuperSyncTasks> Function()? tasks,
  }) : _tasks = tasks,
       launch =
           launch ??
           ((uri) => launchUrl(uri, mode: LaunchMode.externalApplication));

  final Storage storage;
  final ChatSettings chatSettings;
  final Future<bool> Function(Uri uri) launch;
  final Future<SuperSyncTasks> Function()? _tasks;

  /// The to-do list on the SuperSync server.
  Future<SuperSyncTasks> tasks() =>
      _tasks != null ? _tasks() : superSyncTasksFor(storage);
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
      'repeat': {
        'type': 'string',
        'enum': ['daily', 'weekly', 'monthly', 'yearly'],
        'description':
            'Make the event repeat. It repeats forever unless repeat_until is given.',
      },
      'repeat_interval': {
        'type': 'integer',
        'description':
            'Repeat every this many days, weeks, months or years, 1 by default',
      },
      'repeat_days': {
        'type': 'array',
        'items': {'type': 'string'},
        'description':
            'For a weekly repeat, the days of the week, like ["monday", "wednesday"]. Defaults to the weekday of the start.',
      },
      'repeat_until': _str(
        'Last day the event can happen on, like 2026-12-31. Leave out to repeat forever.',
      ),
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
      final String? rrule;
      try {
        rrule = buildRecurrenceRule(args, start, allDay: allDay);
      } on FormatException catch (e) {
        return ToolResult(e.message);
      }
      final id = await NativeBridge.calendarAdd(
        title: title,
        start: start,
        end: end,
        allDay: allDay,
        recurrenceRule: rrule,
        location: _optArg(args, 'location'),
        description: _optArg(args, 'description'),
        reminderMinutes: _optIntArg(args, 'reminder_minutes'),
      );
      if (id == null) {
        return const ToolResult(
          'There is no calendar on the device that can be written to.',
        );
      }
      final repeats = rrule == null
          ? ''
          : _optArg(args, 'repeat_until') == null
          ? ', repeating forever'
          : ', repeating until ${_optArg(args, 'repeat_until')}';
      return ToolResult(
        'Added "$title" to the calendar$repeats, event id $id.',
      );
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
    name: 'list_tasks',
    description:
        'List the tasks of the user\'s to-do list (Super Productivity). Finished tasks are left out unless asked for.',
    properties: {
      'include_done': {
        'type': 'boolean',
        'description': 'Also list the tasks that are done',
      },
      'project': _str('Only the tasks of this project, by name'),
      'search': _str('Only tasks whose title or notes contain this text'),
      'due_from': _str(
        'Only tasks due on or after this, like 2026-10-08 or 2026-10-08T15:00. Tasks without a due date are left out.',
      ),
      'due_to': _str(
        'Only tasks due on or before this, like 2026-10-15. A date without a time includes that whole day.',
      ),
    },
    required: const [],
    defaultMode: ToolMode.auto,
    describeCall: (_) => 'Read the task list',
    run: (args, ctx) async {
      final dueFrom = _optDateArg(args, 'due_from');
      var dueBefore = _optDateArg(args, 'due_to');
      if (dueBefore != null) {
        final dateOnly = RegExp(
          r'^\d{4}-\d{2}-\d{2}$',
        ).hasMatch(_optArg(args, 'due_to')!);
        // "on or before" a date includes the whole day, a moment includes that minute
        dueBefore = dateOnly
            ? DateTime(dueBefore.year, dueBefore.month, dueBefore.day + 1)
            : dueBefore.add(const Duration(minutes: 1));
      }
      if (dueFrom != null && dueBefore != null && !dueBefore.isAfter(dueFrom)) {
        return const ToolResult('"due_to" must not be before "due_from".');
      }
      final tasks = await ctx.tasks();
      final items = await tasks.list(
        includeDone: args['include_done'] == true,
        project: _optArg(args, 'project'),
        search: _optArg(args, 'search'),
        dueFrom: dueFrom,
        dueBefore: dueBefore,
      );
      if (items.isEmpty) return const ToolResult('No tasks.');
      final hint = tasks.ignoredOperations > 0
          ? '\n(${tasks.ignoredOperations} changes of unsupported kinds were not applied, so the list can be slightly out of date.)'
          : '';
      return ToolResult('${items.map(describeTask).join('\n')}$hint');
    },
  ),
  AssistantTool(
    name: 'add_task',
    description:
        'Add a task to the user\'s to-do list (Super Productivity). Without a project it goes to the Inbox.',
    properties: {
      'title': _str('What has to be done'),
      'due': _str(
        'Optional due date like 2026-10-08, or date and time in local time like 2026-10-08T15:00',
      ),
      'project': _str('Optional project name'),
      'notes': _str('Optional details'),
    },
    required: const ['title'],
    defaultMode: ToolMode.confirm,
    describeCall: (a) => 'Add the task "${a['title']}"',
    run: (args, ctx) async {
      final due = _dueArg(args);
      final task = await (await ctx.tasks()).add(
        _arg(args, 'title'),
        notes: _optArg(args, 'notes'),
        project: _optArg(args, 'project'),
        dueDay: due?.day,
        dueWithTime: due?.time,
      );
      return ToolResult('Added: ${describeTask(task)}');
    },
  ),
  AssistantTool(
    name: 'update_task',
    description:
        'Change a task of the to-do list, or mark it done or not done. Find it by id or by title.',
    properties: {
      'id': _str('Task id from list_tasks'),
      'title': _str('Current title, if the id is not known'),
      'new_title': _str('New title'),
      'notes': _str('New details'),
      'done': {
        'type': 'boolean',
        'description': 'True when the task is finished',
      },
      'due': _str(
        'New due date like 2026-10-08, or date and time like 2026-10-08T15:00. "none" removes it.',
      ),
      'project': _str('Move the task to this project, by name'),
    },
    required: const [],
    defaultMode: ToolMode.confirm,
    describeCall: (a) => 'Change the task "${a['title'] ?? a['id']}"',
    run: (args, ctx) async {
      final tasks = await ctx.tasks();
      final target = await tasks.find(
        id: _optArg(args, 'id'),
        title: _optArg(args, 'title'),
      );
      final done = args['done'] is bool ? args['done'] as bool : null;
      final changesAnythingElse = [
        'new_title',
        'notes',
        'due',
        'project',
      ].any((k) => _optArg(args, k) != null);
      if (done != null && done == target.isDone && !changesAnythingElse) {
        return ToolResult(
          'No change: the task "${target.title}" [${target.id}] is already ${done ? 'done' : 'not done'}.',
        );
      }
      final clearDue = _optArg(args, 'due')?.toLowerCase() == 'none';
      final due = clearDue ? null : _dueArg(args);
      final updated = await tasks.update(
        target,
        title: _optArg(args, 'new_title'),
        notes: _optArg(args, 'notes'),
        isDone: done,
        project: _optArg(args, 'project'),
        dueDay: due?.day,
        dueWithTime: due?.time,
        clearDue: clearDue,
      );
      return ToolResult('Updated: ${describeTask(updated)}');
    },
  ),
  AssistantTool(
    name: 'delete_task',
    description:
        'Delete a task, and its subtasks, from the to-do list. Find it by id or by title.',
    properties: {
      'id': _str('Task id from list_tasks'),
      'title': _str('Title, if the id is not known'),
    },
    required: const [],
    defaultMode: ToolMode.confirm,
    describeCall: (a) => 'Delete the task "${a['title'] ?? a['id']}"',
    run: (args, ctx) async {
      final tasks = await ctx.tasks();
      final target = await tasks.find(
        id: _optArg(args, 'id'),
        title: _optArg(args, 'title'),
      );
      await tasks.delete(target);
      return ToolResult('Deleted the task "${target.title}".');
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

const _rruleFrequencies = {
  'daily': 'DAILY',
  'weekly': 'WEEKLY',
  'monthly': 'MONTHLY',
  'yearly': 'YEARLY',
};

const _rruleDays = ['SU', 'MO', 'TU', 'WE', 'TH', 'FR', 'SA'];

/// The iCalendar RRULE for the "repeat*" arguments, or null if the event does not repeat.
/// Without "repeat_until" the rule has no end. Throws a [FormatException] with a message
/// meant for the model.
String? buildRecurrenceRule(
  Map<String, dynamic> args,
  DateTime start, {
  required bool allDay,
}) {
  final repeat = _optArg(args, 'repeat')?.toLowerCase();
  if (repeat == null || repeat == 'none') return null;
  final freq = _rruleFrequencies[repeat];
  if (freq == null) {
    throw const FormatException(
      '"repeat" must be daily, weekly, monthly or yearly.',
    );
  }
  final parts = ['FREQ=$freq'];

  final interval = _optIntArg(args, 'repeat_interval') ?? 1;
  if (interval < 1) {
    throw const FormatException('"repeat_interval" must be at least 1.');
  }
  if (interval > 1) parts.add('INTERVAL=$interval');

  final days = args['repeat_days'];
  if (days != null) {
    if (freq != 'WEEKLY') {
      throw const FormatException(
        '"repeat_days" only works with a weekly repeat.',
      );
    }
    final numbers = parseWeekdays(days);
    if (numbers.isNotEmpty) {
      parts.add('BYDAY=${numbers.map((n) => _rruleDays[n - 1]).join(',')}');
    }
  }

  final untilText = _optArg(args, 'repeat_until');
  if (untilText != null) {
    final until = parseLocalDateTime(untilText);
    if (until == null) {
      throw const FormatException(
        '"repeat_until" is not a date. Use the format 2026-12-31.',
      );
    }
    final lastDay = DateTime(until.year, until.month, until.day);
    final firstDay = DateTime(start.year, start.month, start.day);
    if (lastDay.isBefore(firstDay)) {
      throw const FormatException(
        '"repeat_until" must not be before the start.',
      );
    }
    if (allDay) {
      parts.add('UNTIL=${lastDay.year}${_two(lastDay.month)}${_two(lastDay.day)}');
    } else {
      // The last day counts fully, so the limit is the end of that day
      final t = DateTime(lastDay.year, lastDay.month, lastDay.day, 23, 59, 59).toUtc();
      parts.add(
        'UNTIL=${t.year.toString().padLeft(4, '0')}${_two(t.month)}${_two(t.day)}'
        'T${_two(t.hour)}${_two(t.minute)}${_two(t.second)}Z',
      );
    }
  }
  return parts.join(';');
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

String describeTask(SyncedTask t) {
  final due = t.due;
  return '${t.parentId == null ? '' : '  - '}[${t.id}] ${t.isDone ? '(done) ' : ''}${t.title}'
      '${t.projectTitle == null ? '' : ' (project: ${t.projectTitle})'}'
      '${due == null ? '' : ' (due ${t.dueHasTime ? formatMoment(due) : formatDay(due)})'}'
      '${t.notes.isEmpty ? '' : ', notes: ${t.notes}'}';
}

/// "2026-10-08" is a date, "2026-10-08T15:00" a moment.
({String? day, DateTime? time})? _dueArg(Map<String, dynamic> args) {
  final text = _optArg(args, 'due');
  if (text == null || text.toLowerCase() == 'none') return null;
  if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(text)) {
    if (DateTime.tryParse(text) == null) {
      throw Exception('"due" is not a valid date');
    }
    return (day: text, time: null);
  }
  final time = parseLocalDateTime(text);
  if (time == null) {
    throw Exception(
      '"due" must look like 2026-10-08 or 2026-10-08T15:00, in local time.',
    );
  }
  return (day: null, time: time);
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
