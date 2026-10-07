import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/storage.dart';
import 'endpoints_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final storage = context.watch<Storage>();

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.key),
            title: const Text('API endpoints'),
            subtitle: const Text(
              'Hosts and API keys for OpenAI-compatible servers',
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const EndpointsScreen()),
            ),
          ),
          const Divider(),
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
          SwitchListTile(
            secondary: const Icon(Icons.psychology_outlined),
            title: const Text('Show reasoning'),
            subtitle: const Text(
              'Display the model\'s thinking when the server returns it',
            ),
            value: storage.showReasoning,
            onChanged: storage.setShowReasoning,
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
}
