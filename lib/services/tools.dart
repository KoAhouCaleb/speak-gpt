import 'package:url_launcher/url_launcher.dart';

import '../models/models.dart';
import 'image_client.dart';
import 'native_bridge.dart';
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
        'Open the messaging app with a prepared text message. The user presses send.',
    properties: {
      'contact': _str('Contact name or a phone number'),
      'message': _str('Text of the message'),
    },
    required: const ['contact', 'message'],
    defaultMode: ToolMode.confirm,
    describeCall: (a) => 'Text "${a['contact']}": ${a['message']}',
    run: (args, ctx) async {
      final number = await _resolveNumber(_arg(args, 'contact'));
      if (number == null) {
        return ToolResult('No contact matches "${args['contact']}".');
      }
      final uri = Uri(
        scheme: 'sms',
        path: number.$2,
        queryParameters: {'body': _arg(args, 'message')},
      );
      return _open(ctx, uri, 'Message to ${number.$1} prepared.');
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
];

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
