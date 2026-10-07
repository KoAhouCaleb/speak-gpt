import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/storage.dart';
import 'dialogs.dart';

class EndpointsScreen extends StatelessWidget {
  const EndpointsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final storage = context.watch<Storage>();
    final endpoints = storage.endpoints;

    return Scaffold(
      appBar: AppBar(title: const Text('API endpoints')),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Add endpoint',
        onPressed: () => _edit(context, null),
        child: const Icon(Icons.add),
      ),
      body: ListView.builder(
        itemCount: endpoints.length,
        itemBuilder: (context, i) {
          final e = endpoints[i];
          return ListTile(
            title: Text(e.label),
            subtitle: Text(
              e.host,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: e.apiKey.isEmpty
                ? const Icon(Icons.warning_amber, semanticLabel: 'No API key')
                : null,
            onTap: () => _edit(context, e),
            onLongPress: () async {
              final ok = await confirm(
                context,
                title: 'Delete endpoint',
                message: 'Delete "${e.label}"?',
              );
              if (ok) await storage.deleteEndpoint(e);
            },
          );
        },
      ),
    );
  }

  Future<void> _edit(BuildContext context, ApiEndpoint? existing) async {
    final storage = context.read<Storage>();
    final label = TextEditingController(text: existing?.label ?? '');
    final host = TextEditingController(
      text: existing?.host ?? 'https://api.openai.com/v1/',
    );
    final key = TextEditingController(text: existing?.apiKey ?? '');

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? 'Add endpoint' : 'Edit endpoint'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: label,
                enabled: existing == null,
                decoration: const InputDecoration(labelText: 'Label'),
              ),
              TextField(
                controller: host,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(labelText: 'Base URL'),
              ),
              TextField(
                controller: key,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'API key'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (saved == true &&
        label.text.trim().isNotEmpty &&
        host.text.trim().isNotEmpty) {
      await storage.saveEndpoint(
        ApiEndpoint(
          label: label.text.trim(),
          host: host.text.trim(),
          apiKey: key.text.trim(),
        ),
      );
    }
    label.dispose();
    host.dispose();
    key.dispose();
  }
}
