import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/native_bridge.dart';
import '../services/storage.dart';
import 'chat_screen.dart';
import 'dialogs.dart';

class ChatsScreen extends StatelessWidget {
  const ChatsScreen({super.key});

  Future<void> _newChat(BuildContext context) async {
    final storage = context.read<Storage>();
    final name = await promptText(
      context,
      title: 'New chat',
      label: 'Chat name',
      initial: storage.availableChatName(),
      validator: (v) {
        if (v.trim().isEmpty) return 'Name must not be empty';
        if (storage.chatExists(v.trim())) {
          return 'A chat with this name already exists';
        }
        return null;
      },
    );
    if (name == null || !context.mounted) return;
    final info = await storage.addChat(name.trim());
    if (context.mounted) openChat(context, info);
  }

  @override
  Widget build(BuildContext context) {
    final storage = context.watch<Storage>();
    final chats = storage.chats;

    return Scaffold(
      appBar: AppBar(title: const Text('Grace')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _newChat(context),
        icon: const Icon(Icons.add),
        label: const Text('New chat'),
      ),
      body: chats.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'No chats yet. Start a new one, or pick a preset in Explore.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.only(bottom: 88),
              itemCount: chats.length,
              itemBuilder: (context, i) => _ChatTile(chat: chats[i]),
            ),
    );
  }
}

class _ChatTile extends StatelessWidget {
  const _ChatTile({required this.chat});

  final ChatInfo chat;

  @override
  Widget build(BuildContext context) {
    final storage = context.read<Storage>();
    final messages = storage.messages(chat.id);
    final preview = messages.isEmpty
        ? 'No messages yet.'
        : messages.first.text.replaceAll('\n', ' ');

    return ListTile(
      leading: CircleAvatar(
        child: Text(chat.name.isEmpty ? '?' : chat.name[0].toUpperCase()),
      ),
      title: Text(chat.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(preview, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: chat.pinned ? const Icon(Icons.push_pin, size: 18) : null,
      onTap: () => openChat(context, chat),
      onLongPress: () => _showActions(context, storage),
    );
  }

  void _showActions(BuildContext context, Storage storage) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                chat.pinned ? Icons.push_pin_outlined : Icons.push_pin,
              ),
              title: Text(chat.pinned ? 'Unpin' : 'Pin'),
              onTap: () {
                Navigator.pop(sheet);
                storage.togglePin(chat);
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Rename'),
              onTap: () async {
                Navigator.pop(sheet);
                final name = await promptText(
                  context,
                  title: 'Rename chat',
                  label: 'Chat name',
                  initial: chat.name,
                  validator: (v) {
                    if (v.trim().isEmpty) return 'Name must not be empty';
                    if (v.trim() != chat.name && storage.chatExists(v.trim())) {
                      return 'A chat with this name already exists';
                    }
                    return null;
                  },
                );
                if (name != null) await storage.renameChat(chat, name.trim());
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete'),
              onTap: () async {
                Navigator.pop(sheet);
                final ok = await confirm(
                  context,
                  title: 'Delete chat',
                  message: 'Delete "${chat.name}" and all of its messages?',
                );
                if (ok) await storage.deleteChat(chat);
              },
            ),
          ],
        ),
      ),
    );
  }
}

void openChat(BuildContext context, ChatInfo chat, {AssistContext? assist}) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ChatScreen(chat: chat, assist: assist),
    ),
  );
}
