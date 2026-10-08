import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/storage.dart';
import '../services/tools.dart';

/// Chooses which tools the model may call and whether each call needs approval.
class ToolsScreen extends StatefulWidget {
  const ToolsScreen({super.key});

  @override
  State<ToolsScreen> createState() => _ToolsScreenState();
}

class _ToolsScreenState extends State<ToolsScreen> {
  late final TextEditingController _searx;

  @override
  void initState() {
    super.initState();
    _searx = TextEditingController(text: context.read<Storage>().searxngUrl);
  }

  @override
  void dispose() {
    _searx.dispose();
    super.dispose();
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
