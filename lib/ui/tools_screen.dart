import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/storage.dart';
import '../services/supersync/supersync_factory.dart';
import '../services/tools.dart';

/// Chooses which tools the model may call and whether each call needs approval.
class ToolsScreen extends StatefulWidget {
  const ToolsScreen({super.key});

  @override
  State<ToolsScreen> createState() => _ToolsScreenState();
}

class _ToolsScreenState extends State<ToolsScreen> {
  late final TextEditingController _searx;
  late final TextEditingController _syncUrl;
  late final TextEditingController _syncToken;
  late final TextEditingController _syncPassword;
  late final TextEditingController _syncCert;
  String? _syncStatus;
  bool _syncBusy = false;

  @override
  void initState() {
    super.initState();
    final storage = context.read<Storage>();
    _searx = TextEditingController(text: storage.searxngUrl);
    _syncUrl = TextEditingController(text: storage.supersyncUrl);
    _syncToken = TextEditingController(text: storage.supersyncToken);
    _syncPassword = TextEditingController(text: storage.supersyncPassword);
    _syncCert = TextEditingController(text: storage.supersyncCertificate);
  }

  @override
  void dispose() {
    _searx.dispose();
    _syncUrl.dispose();
    _syncToken.dispose();
    _syncPassword.dispose();
    _syncCert.dispose();
    super.dispose();
  }

  Future<void> _saveAndTestSync() async {
    final storage = context.read<Storage>();
    setState(() {
      _syncBusy = true;
      _syncStatus = null;
    });
    await storage.saveSupersync(
      url: _syncUrl.text,
      token: _syncToken.text,
      password: _syncPassword.text,
      certificate: _syncCert.text,
    );
    String status;
    try {
      final tasks = await superSyncTasksFor(storage);
      final state = await tasks.sync();
      status =
          'Connected. ${state.tasks.length} tasks and ${state.projects.length} projects found.';
    } catch (e) {
      status = e.toString().replaceFirst('Exception: ', '');
    }
    if (!mounted) return;
    setState(() {
      _syncBusy = false;
      _syncStatus = status;
    });
  }

  static const _labels = {
    ToolMode.disabled: 'Off',
    ToolMode.confirm: 'Ask each time',
    ToolMode.auto: 'Allow',
  };

  @override
  Widget build(BuildContext context) {
    final storage = context.watch<Storage>();

    return Scaffold(
      appBar: AppBar(title: const Text('Tools')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Use tools in new chats'),
            subtitle: const Text(
              'Chats you already have keep their own setting (chat settings > Tools). '
              'The model must support function calling.',
            ),
            value: storage.defaultChatSettings.functionCalling,
            onChanged: (v) => storage.saveDefaultChatSettings(
              storage.defaultChatSettings..functionCalling = v,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _searx,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'SearXNG instance URL',
              helperText:
                  'Used by internet search. The instance must allow the json format.',
              border: OutlineInputBorder(),
            ),
            onChanged: storage.setSearxngUrl,
          ),
          const SizedBox(height: 16),
          const Divider(height: 32),
          Text(
            'Task server (Super Productivity)',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'The task tools read and change your to-do list through a SuperSync server. '
            'Use the same access token and encryption password as the Super Productivity app. '
            'Nothing is stored in Grace except a copy of the list for speed.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _syncUrl,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Server URL',
              hintText: 'https://sync.example.home',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _syncToken,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Access token',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _syncPassword,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Encryption password',
              helperText:
                  'The sync server only accepts encrypted data, so this is required.',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _syncCert,
            minLines: 1,
            maxLines: 6,
            decoration: const InputDecoration(
              labelText: 'Server certificate (optional)',
              helperText:
                  'PEM text of a self-signed certificate. Not needed if its authority is installed on the device.',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              onPressed: _syncBusy ? null : _saveAndTestSync,
              child: Text(_syncBusy ? 'Connecting...' : 'Save and test'),
            ),
          ),
          if (_syncStatus != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_syncStatus!),
            ),
          const Divider(height: 32),
          for (final tool in allTools)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tool.name),
              subtitle: Text(tool.description),
              trailing: DropdownButton<ToolMode>(
                value: tool.mode(storage),
                underline: const SizedBox.shrink(),
                items: [
                  for (final m in ToolMode.values)
                    DropdownMenuItem(value: m, child: Text(_labels[m]!)),
                ],
                onChanged: (m) {
                  if (m != null) storage.setToolMode(tool.name, m.name);
                },
              ),
            ),
        ],
      ),
    );
  }
}
