import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../models/models.dart';
import 'image_viewer.dart';

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.showReasoning,
    required this.streaming,
    required this.onCopy,
    required this.onSpeak,
    required this.onEdit,
    required this.onDelete,
    this.onRegenerate,
  });

  final ChatMessage message;
  final bool showReasoning;
  final bool streaming;
  final VoidCallback onCopy;
  final VoidCallback onSpeak;
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
                if (message.toolLog.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.build_outlined,
                          size: 16,
                          color: foreground.withValues(alpha: 0.7),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            message.toolLog,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (message.imagePath.isNotEmpty &&
                    File(message.imagePath).existsSync())
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: GestureDetector(
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              ImageViewerScreen(path: message.imagePath),
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.file(
                          File(message.imagePath),
                          width: 260,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                  ),
                if (message.contextText.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      'Screen text attached',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
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
                      : message.text.isEmpty
                      ? const SizedBox.shrink()
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
                else if (message.text.isNotEmpty)
                  SelectableText(
                    message.text,
                    style: TextStyle(color: foreground),
                  ),
                if (message.errorText.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.error_outline,
                          size: 18,
                          color: scheme.error,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: SelectableText(
                            message.errorText,
                            style: TextStyle(color: scheme.error),
                          ),
                        ),
                      ],
                    ),
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
            if (message.isBot)
              ListTile(
                leading: const Icon(Icons.volume_up_outlined),
                title: const Text('Read aloud'),
                onTap: () {
                  Navigator.pop(sheet);
                  onSpeak();
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
