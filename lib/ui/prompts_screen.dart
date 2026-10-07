import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/storage.dart';
import 'chats_screen.dart';
import 'dialogs.dart';

/// Saved prompts. A prompt can start a chat as its system message or as the first message.
class PromptsScreen extends StatelessWidget {
  const PromptsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final storage = context.watch<Storage>();
    final prompts = storage.prompts;

    return Scaffold(
      appBar: AppBar(title: const Text('Prompts')),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Add prompt',
        onPressed: () => _edit(context, storage, null),
        child: const Icon(Icons.add),
      ),
      body: prompts.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Save prompts you use often and start a chat with them in one tap.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.builder(
              itemCount: prompts.length,
              itemBuilder: (context, i) => ListTile(
                title: Text(prompts[i].title),
                subtitle: Text(
                  prompts[i].text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => _actions(context, storage, prompts[i]),
              ),
            ),
    );
  }

  void _actions(BuildContext context, Storage storage, SavedPrompt prompt) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.settings_suggest_outlined),
              title: const Text('Start chat with it as system message'),
              onTap: () async {
                Navigator.pop(sheet);
                final settings = storage.defaultChatSettings
                  ..systemMessage = prompt.text;
                final info = await storage.addChat(
                  storage.availableChatName(prompt.title),
                  settings: settings,
                );
                if (context.mounted) openChat(context, info);
              },
            ),
            ListTile(
              leading: const Icon(Icons.chat_outlined),
              title: const Text('Start chat and send it'),
              onTap: () async {
                Navigator.pop(sheet);
                final info = await storage.addChat(
                  storage.availableChatName(prompt.title),
                );
                await storage.saveMessages(info.id, [
                  ChatMessage(text: prompt.text, isBot: false),
                ]);
                if (context.mounted) openChat(context, info);
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit'),
              onTap: () {
                Navigator.pop(sheet);
                _edit(context, storage, prompt);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete'),
              onTap: () async {
                Navigator.pop(sheet);
                final ok = await confirm(
                  context,
                  title: 'Delete prompt',
                  message: 'Delete "${prompt.title}"?',
                );
                if (ok) await storage.deletePrompt(prompt.id);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _edit(
    BuildContext context,
    Storage storage,
    SavedPrompt? existing,
  ) async {
    final title = TextEditingController(text: existing?.title ?? '');
    final text = TextEditingController(text: existing?.text ?? '');

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? 'Add prompt' : 'Edit prompt'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: title,
                decoration: const InputDecoration(labelText: 'Title'),
              ),
              TextField(
                controller: text,
                minLines: 4,
                maxLines: 10,
                decoration: const InputDecoration(labelText: 'Prompt'),
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
        title.text.trim().isNotEmpty &&
        text.text.trim().isNotEmpty) {
      await storage.savePrompt(
        SavedPrompt(
          id:
              existing?.id ??
              sha256Hex(
                '${DateTime.now().microsecondsSinceEpoch}${title.text}',
              ),
          title: title.text.trim(),
          text: text.text.trim(),
        ),
      );
    }
    title.dispose();
    text.dispose();
  }
}
