import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/models.dart';
import '../services/chat_session.dart';
import '../services/native_bridge.dart';
import '../services/speech_service.dart';
import '../services/storage.dart';
import '../services/tools.dart';
import '../util.dart';
import 'chat_settings_screen.dart';
import 'dialogs.dart';
import 'message_bubble.dart';
import 'message_input.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.chat, this.assist});

  final ChatInfo chat;

  /// Screen content captured when the chat was opened through the assistant gesture.
  final AssistContext? assist;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final ChatSession _session;
  late final Storage _storage;
  late final SpeechService _speech;
  final _input = TextEditingController();
  final _scroll = ScrollController();

  String _attachedImage = '';
  bool _attachScreenText = false;
  bool _attachScreenshot = false;
  bool _listening = false;

  // The message in the box came from dictation, so the answer may be read aloud
  bool _voiceInput = false;
  String _dictationBase = '';

  @override
  void initState() {
    super.initState();
    _storage = context.read<Storage>();
    _speech = SpeechService(_storage);
    _session = ChatSession(_storage, widget.chat.id)
      ..addListener(_onChange)
      ..confirmTool = _confirmTool
      // The session decides whether this answer is read aloud (silent / always speak modes)
      ..onAnswer = _speak;

    final assist = widget.assist;
    if (assist != null && _storage.autoAttachScreen) {
      _attachScreenText = assist.text.trim().isNotEmpty;
      _attachScreenshot = assist.screenshotPath.isNotEmpty;
    }
  }

  @override
  void dispose() {
    _session.removeListener(_onChange);
    _session.dispose();
    _speech.dispose();
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

  Future<bool> _confirmTool(
    AssistantTool tool,
    Map<String, dynamic> args,
  ) async {
    if (!mounted) return false;
    return confirmToolDialog(context, tool, args);
  }

  Future<void> _send({bool fromVoice = false}) async {
    if (_listening) await _stopListening();
    final dictated = fromVoice || _voiceInput;
    _voiceInput = false;
    final text = _input.text;
    final assist = widget.assist;

    var image = _attachedImage;
    if (image.isEmpty && _attachScreenshot && assist != null) {
      image = assist.screenshotPath;
    }
    final contextText = _attachScreenText && assist != null ? assist.text : '';

    if (text.trim().isEmpty && image.isEmpty && contextText.isEmpty) return;

    // Files in the cache folder can disappear, keep a copy with the chat
    if (image.isNotEmpty) {
      try {
        image = await persistImage(image);
      } catch (_) {
        image = '';
      }
    }

    _input.clear();
    setState(() {
      _attachedImage = '';
      // The screen is attached to the first message only
      _attachScreenText = false;
      _attachScreenshot = false;
    });
    await _session.send(
      text,
      imagePath: image,
      contextText: contextText,
      fromVoice: dictated,
    );
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final file = await ImagePicker().pickImage(
        source: source,
        maxWidth: 1600,
        imageQuality: 85,
      );
      if (file != null && mounted) setState(() => _attachedImage = file.path);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not get the picture: $e')),
        );
      }
    }
  }

  void _showAttachMenu() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose a picture'),
              onTap: () {
                Navigator.pop(sheet);
                _pickImage(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a picture'),
              onTap: () {
                Navigator.pop(sheet);
                _pickImage(ImageSource.camera);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggleListening() async {
    if (_listening) {
      await _stopListening();
      return;
    }

    _dictationBase = _input.text.isEmpty ? '' : '${_input.text.trimRight()} ';
    final ok = await _speech.listen(
      locale: _storage.speechLocale,
      onResult: (text, isFinal) {
        if (!mounted) return;
        _input.value = TextEditingValue(
          text: '$_dictationBase$text',
          selection: TextSelection.collapsed(
            offset: '$_dictationBase$text'.length,
          ),
        );
        if (text.trim().isNotEmpty) _voiceInput = true;
        if (isFinal && text.trim().isNotEmpty && _storage.autoSend) {
          _send(fromVoice: true);
        }
      },
      onError: (e) {
        if (mounted) setState(() => _listening = false);
      },
      onDone: () {
        if (mounted) setState(() => _listening = false);
      },
    );

    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Speech recognition is not available. Check the microphone permission.',
          ),
        ),
      );
      return;
    }
    setState(() => _listening = true);
  }

  Future<void> _speak(String text) async {
    final error = await _speech.speak(
      text,
      locale: _storage.speechLocale,
      endpoint: _storage.endpointById(_session.settings.endpointId),
    );
    if (error != null && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not read aloud: $error')));
    }
  }

  Future<void> _stopListening() async {
    await _speech.stopListening();
    if (mounted) setState(() => _listening = false);
  }

  void _share() {
    final name = _session.settings.assistantName;
    Share.share(
      transcript(
        widget.chat.name,
        _session.messages.map((m) => (isBot: m.isBot, text: m.text)),
        name,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final storage = context.watch<Storage>();
    final settings = _session.settings;
    final messages = _session.messages;
    final assist = widget.assist;
    final assistEmpty = assist != null && assist.isEmpty;

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
              } else if (v == 'share') {
                _share();
              } else if (v == 'silence') {
                await _speech.stopSpeaking();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'share', child: Text('Share chat')),
              PopupMenuItem(value: 'silence', child: Text('Stop speaking')),
              PopupMenuItem(value: 'clear', child: Text('Clear chat')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (assistEmpty)
            MaterialBanner(
              leading: const Icon(Icons.info_outline),
              content: const Text(
                'Grace did not receive the screen. In the system settings for the digital assistant, '
                'turn on "Use text from screen" and "Use screenshot".',
              ),
              actions: [
                TextButton(
                  onPressed: NativeBridge.openAssistantSettings,
                  child: const Text('Open settings'),
                ),
              ],
            ),
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
                    itemBuilder: (context, i) => MessageBubble(
                      message: messages[i],
                      showReasoning: storage.showReasoning,
                      streaming:
                          _session.generating &&
                          i == messages.length - 1 &&
                          messages[i].isBot,
                      onCopy: () => Clipboard.setData(
                        ClipboardData(text: messages[i].text),
                      ),
                      onSpeak: () => _speak(messages[i].text),
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
          _attachments(assist),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 12, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    tooltip: 'Attach a picture',
                    onPressed: _showAttachMenu,
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                  ),
                  Expanded(
                    child: MessageInput(
                      controller: _input,
                      onImage: (path) => setState(() => _attachedImage = path),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: _listening ? 'Stop dictation' : 'Dictate',
                    onPressed: _toggleListening,
                    color: _listening
                        ? Theme.of(context).colorScheme.error
                        : null,
                    icon: Icon(_listening ? Icons.mic : Icons.mic_none),
                  ),
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

  Widget _attachments(AssistContext? assist) {
    final chips = <Widget>[];

    if (assist != null && assist.text.trim().isNotEmpty) {
      chips.add(
        FilterChip(
          avatar: const Icon(Icons.article_outlined, size: 18),
          label: Text('Screen text (${assist.text.length})'),
          selected: _attachScreenText,
          onSelected: (v) => setState(() => _attachScreenText = v),
        ),
      );
    }
    if (assist != null && assist.screenshotPath.isNotEmpty) {
      chips.add(
        FilterChip(
          avatar: const Icon(Icons.screenshot_outlined, size: 18),
          label: const Text('Screenshot'),
          selected: _attachScreenshot && _attachedImage.isEmpty,
          onSelected: (v) => setState(() => _attachScreenshot = v),
        ),
      );
    }

    if (_attachedImage.isNotEmpty) {
      chips.add(
        InputChip(
          avatar: ClipOval(
            child: Image.file(
              File(_attachedImage),
              width: 24,
              height: 24,
              fit: BoxFit.cover,
            ),
          ),
          label: const Text('Picture'),
          onDeleted: () => setState(() => _attachedImage = ''),
        ),
      );
    }

    if (chips.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Wrap(spacing: 8, children: chips),
      ),
    );
  }
}
