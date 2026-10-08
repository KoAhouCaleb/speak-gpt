import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../services/native_bridge.dart';

/// The message text box. Besides typing it accepts pictures in two ways:
///
/// * the keyboard can insert an image (Gboard clipboard suggestions, stickers, GIFs),
/// * when the clipboard holds a picture the selection menu offers "Paste image".
///
/// Flutter's own paste only understands text, so the picture on the clipboard is read natively.
class MessageInput extends StatefulWidget {
  const MessageInput({
    super.key,
    required this.controller,
    required this.onImage,
    this.hint = 'Message',
    this.autofocus = false,
    this.minLines = 1,
    this.maxLines = 6,
    this.onSubmitted,
  });

  final TextEditingController controller;

  /// Called with the path of a picture that was pasted or inserted.
  final void Function(String path) onImage;
  final String hint;
  final bool autofocus;
  final int minLines;
  final int maxLines;
  final VoidCallback? onSubmitted;

  @override
  State<MessageInput> createState() => _MessageInputState();
}

class _MessageInputState extends State<MessageInput>
    with WidgetsBindingObserver {
  final FocusNode _focus = FocusNode();
  bool _clipboardHasImage = false;

  static const _imageTypes = [
    'image/png',
    'image/jpeg',
    'image/webp',
    'image/gif',
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _focus.addListener(_refreshClipboard);
    _refreshClipboard();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _focus.removeListener(_refreshClipboard);
    _focus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshClipboard();
  }

  // Android only lets an app read the clipboard while it has focus, so this runs on focus and resume
  Future<void> _refreshClipboard() async {
    final has = await NativeBridge.clipboardHasImage();
    if (mounted && has != _clipboardHasImage) {
      setState(() => _clipboardHasImage = has);
    }
  }

  Future<void> _pasteImage() async {
    final path = await NativeBridge.clipboardImage();
    if (!mounted) return;
    if (path == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('There is no picture on the clipboard.')),
      );
      return;
    }
    widget.onImage(path);
  }

  Future<void> _insertedByKeyboard(KeyboardInsertedContent content) async {
    final data = content.data;
    if (data == null || data.isEmpty) return;
    final dir = await getTemporaryDirectory();
    final extension = switch (content.mimeType) {
      'image/png' => 'png',
      'image/webp' => 'webp',
      'image/gif' => 'gif',
      _ => 'jpg',
    };
    final file = File(
      '${dir.path}/keyboard_${DateTime.now().microsecondsSinceEpoch}.$extension',
    );
    await file.writeAsBytes(data);
    if (mounted) widget.onImage(file.path);
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      focusNode: _focus,
      autofocus: widget.autofocus,
      minLines: widget.minLines,
      maxLines: widget.maxLines,
      textCapitalization: TextCapitalization.sentences,
      contentInsertionConfiguration: ContentInsertionConfiguration(
        allowedMimeTypes: _imageTypes,
        onContentInserted: _insertedByKeyboard,
      ),
      contextMenuBuilder: (context, editableTextState) {
        return AdaptiveTextSelectionToolbar.buttonItems(
          anchors: editableTextState.contextMenuAnchors,
          buttonItems: [
            if (_clipboardHasImage)
              ContextMenuButtonItem(
                label: 'Paste image',
                onPressed: () {
                  editableTextState.hideToolbar();
                  _pasteImage();
                },
              ),
            ...editableTextState.contextMenuButtonItems,
          ],
        );
      },
      decoration: InputDecoration(
        hintText: widget.hint,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 10,
        ),
      ),
      onSubmitted: widget.onSubmitted == null
          ? null
          : (_) => widget.onSubmitted!(),
    );
  }
}
