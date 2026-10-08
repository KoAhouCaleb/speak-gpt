import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/native_bridge.dart';
import '../services/storage.dart';
import 'chat_settings_screen.dart';
import 'endpoints_screen.dart';
import 'images_screen.dart';
import 'logit_bias_screen.dart';
import 'prompts_screen.dart';
import 'tools_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  bool _isAssistant = false;
  late final TextEditingController _locale;
  late final TextEditingController _imageModel;

  @override
  void initState() {
    super.initState();
    final storage = context.read<Storage>();
    _locale = TextEditingController(text: storage.speechLocale);
    _imageModel = TextEditingController(text: storage.imageModel);
    WidgetsBinding.instance.addObserver(this);
    _refreshAssistant();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _locale.dispose();
    _imageModel.dispose();
    super.dispose();
  }

  // The user comes back from the system settings after picking the assistant
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshAssistant();
  }

  Future<void> _refreshAssistant() async {
    final value = await NativeBridge.isDefaultAssistant();
    if (mounted) setState(() => _isAssistant = value);
  }

  void _push(Widget screen) => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    final storage = context.watch<Storage>();

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          _header('Chat'),
          ListTile(
            leading: const Icon(Icons.key),
            title: const Text('API endpoints'),
            subtitle: const Text(
              'Hosts and API keys for OpenAI-compatible servers',
            ),
            onTap: () => _push(const EndpointsScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.tune),
            title: const Text('Default chat settings'),
            subtitle: const Text(
              'Model, system message and sampling for new chats',
            ),
            onTap: () => _push(const ChatSettingsScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.build_outlined),
            title: const Text('Tools'),
            subtitle: const Text('Search, navigation, calls and other actions'),
            onTap: () => _push(const ToolsScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.format_quote_outlined),
            title: const Text('Prompts'),
            onTap: () => _push(const PromptsScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.scale_outlined),
            title: const Text('Logit bias sets'),
            onTap: () => _push(const LogitBiasListScreen()),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.psychology_outlined),
            title: const Text('Show reasoning'),
            subtitle: const Text(
              'Display the model\'s thinking when the server returns it',
            ),
            value: storage.showReasoning,
            onChanged: storage.setShowReasoning,
          ),
          _header('Assistant'),
          ListTile(
            leading: Icon(
              _isAssistant
                  ? Icons.check_circle_outline
                  : Icons.assistant_outlined,
            ),
            title: Text(
              _isAssistant
                  ? 'Grace is your digital assistant'
                  : 'Set Grace as digital assistant',
            ),
            subtitle: const Text(
              'Lets you open Grace from any screen with the assistant gesture. In the system settings, also turn on '
              '"Use text from screen" and "Use screenshot" so Grace can see what you are looking at.',
            ),
            onTap: NativeBridge.openAssistantSettings,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.picture_in_picture_alt_outlined),
            title: const Text('Compact assistant'),
            subtitle: const Text(
              'Open the assistant as a small sheet over the current app instead of full screen',
            ),
            value: storage.assistOverlay,
            onChanged: storage.setAssistOverlay,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.screenshot_monitor_outlined),
            title: const Text('Attach the screen automatically'),
            subtitle: const Text(
              'Select the screen text and screenshot when Grace opens from the gesture',
            ),
            value: storage.autoAttachScreen,
            onChanged: storage.setAutoAttachScreen,
          ),
          _header('Voice'),
          SwitchListTile(
            secondary: const Icon(Icons.volume_up_outlined),
            title: const Text('Read answers aloud'),
            value: storage.speakReplies,
            onChanged: storage.setSpeakReplies,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              controller: _locale,
              decoration: const InputDecoration(
                labelText: 'Speech language',
                helperText:
                    'Locale such as en_US or de_DE. Leave empty for the device language.',
                border: OutlineInputBorder(),
              ),
              onChanged: storage.setSpeechLocale,
            ),
          ),
          _header('Images'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              controller: _imageModel,
              decoration: const InputDecoration(
                labelText: 'Image model',
                border: OutlineInputBorder(),
              ),
              onChanged: (v) {
                if (v.trim().isNotEmpty) storage.setImageModel(v.trim());
              },
            ),
          ),
          ListTile(
            title: const Text('Image size'),
            trailing: DropdownButton<String>(
              value:
                  const [
                    '1024x1024',
                    '1536x1024',
                    '1024x1536',
                    '512x512',
                    '256x256',
                  ].contains(storage.imageResolution)
                  ? storage.imageResolution
                  : '1024x1024',
              underline: const SizedBox.shrink(),
              items: const [
                DropdownMenuItem(value: '256x256', child: Text('256x256')),
                DropdownMenuItem(value: '512x512', child: Text('512x512')),
                DropdownMenuItem(value: '1024x1024', child: Text('1024x1024')),
                DropdownMenuItem(value: '1536x1024', child: Text('1536x1024')),
                DropdownMenuItem(value: '1024x1536', child: Text('1024x1536')),
              ],
              onChanged: (v) => storage.setImageResolution(v ?? '1024x1024'),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Image library'),
            onTap: () => _push(const ImagesScreen()),
          ),
          _header('Appearance'),
          ListTile(
            leading: const Icon(Icons.brightness_6_outlined),
            title: const Text('Theme'),
            trailing: DropdownButton<String>(
              value: storage.themeMode,
              underline: const SizedBox.shrink(),
              items: const [
                DropdownMenuItem(value: 'system', child: Text('System')),
                DropdownMenuItem(value: 'light', child: Text('Light')),
                DropdownMenuItem(value: 'dark', child: Text('Dark')),
              ],
              onChanged: (v) => storage.setThemeMode(v ?? 'system'),
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.contrast),
            title: const Text('AMOLED black'),
            subtitle: const Text('Pure black background in dark theme'),
            value: storage.amoled,
            onChanged: storage.setAmoled,
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('About Grace'),
            onTap: () => showAboutDialog(
              context: context,
              applicationName: 'Grace',
              applicationVersion: '4.39.0',
              applicationLegalese:
                  'Based on SpeakGPT by Dmytro Ostapenko. Licensed under the Apache License 2.0.',
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}
