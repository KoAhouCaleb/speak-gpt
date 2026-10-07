import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/chat_session.dart';
import '../services/storage.dart';
import 'chat_settings_screen.dart';
import 'dialogs.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.chat});

  final ChatInfo chat;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final ChatSession _session;
  final _input = TextEditingController();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _session = ChatSession(context.read<Storage>(), widget.chat.id)
      ..addListener(_onChange);
  }

  @override
  void dispose() {
    _session.removeListener(_onChange);
    _session.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    setState(() {});
    if (_session.generating && _scroll.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  void _send() {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    _session.send(text);
  }

  @override
  Widget build(BuildContext context) {
    final storage = context.watch<Storage>();
    final settings = _session.settings;
    final messages = _session.messages;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.chat.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(settings.model, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Chat settings',
            icon: const Icon(Icons.tune),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ChatSettingsScreen(chat: widget.chat),
                ),
              );
              if (mounted) setState(() {});
            },
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'clear') {
                final ok = await confirm(
                  context,
                  title: 'Clear chat',
                  message: 'Delete all messages in this chat?',
                );
                if (ok) await _session.clear();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'clear', child: Text('Clear chat')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: messages.isEmpty
                ? Center(
                    child: Text(
                      'Ask ${settings.assistantName} anything.',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    itemCount: messages.length,
                    itemBuilder: (context, i) => _MessageBubble(
                      message: messages[i],
                      showReasoning: storage.showReasoning,
                      streaming:
                          _session.generating &&
                          i == messages.length - 1 &&
                          messages[i].isBot,
                      onCopy: () => Clipboard.setData(
                        ClipboardData(text: messages[i].text),
                      ),
                      onEdit: () async {
                        final text = await promptText(
                          context,
                          title: 'Edit message',
                          label: 'Message',
                          initial: messages[i].text,
                        );
                        if (text != null) await _session.editMessage(i, text);
                      },
                      onDelete: () => _session.deleteMessage(i),
                      onRegenerate:
                          i == messages.length - 1 && messages[i].isBot
                          ? _session.regenerate
                          : null,
                    ),
                  ),
          ),
          if (_session.error != null)
            MaterialBanner(
              content: SelectableText(_session.error!),
              leading: const Icon(Icons.error_outline),
              actions: [
                TextButton(
                  onPressed: () => setState(() => _session.error = null),
                  child: const Text('Dismiss'),
                ),
              ],
            ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 6,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText: 'Message',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _session.generating
                      ? IconButton.filledTonal(
                          tooltip: 'Stop',
                          onPressed: _session.stop,
                          icon: const Icon(Icons.stop),
                        )
                      : IconButton.filled(
                          tooltip: 'Send',
                          onPressed: _send,
                          icon: const Icon(Icons.send),
                        ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.showReasoning,
    required this.streaming,
    required this.onCopy,
    required this.onEdit,
    required this.onDelete,
    this.onRegenerate,
  });

  final ChatMessage message;
  final bool showReasoning;
  final bool streaming;
  final VoidCallback onCopy;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback? onRegenerate;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isBot = message.isBot;
    final background = isBot
        ? scheme.surfaceContainerHighest
        : scheme.primaryContainer;
    final foreground = isBot ? scheme.onSurface : scheme.onPrimaryContainer;

    return Align(
      alignment: isBot ? Alignment.centerLeft : Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.9,
        ),
        child: GestureDetector(
          onLongPress: () => _showActions(context),
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (isBot && showReasoning && message.reasoning.isNotEmpty)
                  ExpansionTile(
                    key: PageStorageKey('reasoning_${message.hashCode}'),
                    initiallyExpanded: streaming && message.text.isEmpty,
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: const EdgeInsets.only(bottom: 8),
                    title: Text(
                      'Reasoning',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          message.reasoning,
                          style: TextStyle(
                            color: foreground.withValues(alpha: 0.7),
                          ),
                        ),
                      ),
                    ],
                  ),
                if (isBot)
                  message.text.isEmpty && streaming
                      ? const Padding(
                          padding: EdgeInsets.all(4),
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : MarkdownBody(
                          data: message.text,
                          selectable: true,
                          styleSheet:
                              MarkdownStyleSheet.fromTheme(
                                Theme.of(context),
                              ).copyWith(
                                p: TextStyle(color: foreground),
                                code: TextStyle(
                                  fontFamily: 'monospace',
                                  color: foreground,
                                  backgroundColor: scheme.surface,
                                ),
                              ),
                        )
                else
                  SelectableText(
                    message.text,
                    style: TextStyle(color: foreground),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showActions(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copy'),
              onTap: () {
                Navigator.pop(sheet);
                onCopy();
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit'),
              onTap: () {
                Navigator.pop(sheet);
                onEdit();
              },
            ),
            if (onRegenerate != null)
              ListTile(
                leading: const Icon(Icons.refresh),
                title: const Text('Regenerate'),
                onTap: () {
                  Navigator.pop(sheet);
                  onRegenerate!();
                },
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete'),
              onTap: () {
                Navigator.pop(sheet);
                onDelete();
              },
            ),
          ],
        ),
      ),
    );
  }
}
