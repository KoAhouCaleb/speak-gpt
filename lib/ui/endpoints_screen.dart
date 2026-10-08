import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/storage.dart';
import 'dialogs.dart';
import 'form_dialogs.dart';

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
    final saved = await showEndpointDialog(context, existing);
    if (saved != null) await storage.saveEndpoint(saved);
  }
}
