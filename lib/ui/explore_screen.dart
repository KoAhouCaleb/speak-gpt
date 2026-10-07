import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/models.dart';
import '../services/storage.dart';
import 'chats_screen.dart';

/// Presets from assets/ai_sets.json. Starting one creates the endpoint (if needed) and a chat.
class ExploreScreen extends StatefulWidget {
  const ExploreScreen({super.key});

  @override
  State<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends State<ExploreScreen> {
  late final Future<List<AiSet>> _sets = _load();

  Future<List<AiSet>> _load() async {
    final raw = await rootBundle.loadString('assets/ai_sets.json');
    return (jsonDecode(raw) as List)
        .map((e) => AiSet.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> _start(AiSet set) async {
    final storage = context.read<Storage>();

    var endpoint = storage.endpoints
        .where((e) => e.host == set.apiEndpoint)
        .firstOrNull;
    if (endpoint == null) {
      endpoint = ApiEndpoint(label: set.apiEndpointName, host: set.apiEndpoint);
      await storage.saveEndpoint(endpoint);
    }

    final name = storage.availableChatName(
      set.suggestedChatName.isEmpty ? set.name : set.suggestedChatName,
    );
    final info = await storage.addChat(
      name,
      settings: ChatSettings(
        endpointId: endpoint.id,
        model: set.model,
        assistantName: set.assistantName,
      ),
    );

    if (!mounted) return;
    if (endpoint.apiKey.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Add an API key for "${endpoint.label}" in Settings > API endpoints.',
          ),
          action: set.apiKeyUrl.isEmpty
              ? null
              : SnackBarAction(
                  label: 'Get key',
                  onPressed: () => launchUrl(
                    Uri.parse(set.apiKeyUrl),
                    mode: LaunchMode.externalApplication,
                  ),
                ),
        ),
      );
    }
    openChat(context, info);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Explore')),
      body: FutureBuilder<List<AiSet>>(
        future: _sets,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Text('Could not load presets: ${snapshot.error}'),
            );
          }
          final sets = snapshot.data;
          if (sets == null) {
            return const Center(child: CircularProgressIndicator());
          }

          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: sets.length,
            itemBuilder: (context, i) {
              final set = sets[i];
              return Card(
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => _start(set),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          set.name,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          '${set.owner} - ${set.model}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          set.desc,
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
