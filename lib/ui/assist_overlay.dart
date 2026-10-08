import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/chat_session.dart';
import '../services/native_bridge.dart';
import '../services/speech_service.dart';
import '../services/storage.dart';
import '../theme.dart';
import '../util.dart';
import 'dialogs.dart';
import 'message_bubble.dart';
import 'message_input.dart';

/// Root of the assistant overlay engine (see assistOverlayMain in main.dart).
class AssistOverlayApp extends StatelessWidget {
  const AssistOverlayApp({super.key});

  @override
  Widget build(BuildContext context) {
    final storage = context.watch<Storage>();
    return MaterialApp(
      title: 'Grace',
      debugShowCheckedModeBanner: false,
      theme: lightTheme(),
      darkTheme: darkTheme(amoled: storage.amoled),
      themeMode: themeModeOf(storage),
      home: const AssistOverlayScreen(),
    );
  }
}

/// A compact chat sheet shown over the app the user was looking at.
/// The chat is created with the first message, so dismissing the sheet leaves nothing behind.
class AssistOverlayScreen extends StatefulWidget {
  const AssistOverlayScreen({super.key});

  @override
  State<AssistOverlayScreen> createState() => _AssistOverlayScreenState();
}

class _AssistOverlayScreenState extends State<AssistOverlayScreen> {
  late final Storage _storage;
  late final SpeechService _speech;
  final _input = TextEditingController();
  final _scroll = ScrollController();

  AssistContext _captured = const AssistContext();
  bool _attachText = false;
  bool _attachShot = false;

  // A picture that was pasted, inserted by the keyboard or shared into Grace
  String _attachedImage = '';

  // Opened from the assistant gesture, as opposed to the share sheet
  bool _fromAssist = true;

  // The message in the box came from dictation, so the answer may be read aloud
  bool _voiceInput = false;

  ChatInfo? _chat;
  ChatSession? _session;
  bool _listening = false;
  String _dictationBase = '';

  @override
  void initState() {
    super.initState();
    _storage = context.read<Storage>();
    _speech = SpeechService(_storage);
    // Another invocation while the sheet is open starts over
    NativeBridge.listen(onAssist: _startOver, onShare: _startWithShare);
    _loadCapture();
  }

  @override
  void dispose() {
    _session?.dispose();
    _speech.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadCapture() async {
    // The activity was started either by the gesture or by the share sheet
    final share = await NativeBridge.takePendingShare();
    if (share != null) {
      if (mounted) _startWithShare(share);
      return;
    }
    final captured =
        await NativeBridge.takePendingAssist() ?? const AssistContext();
    if (mounted) _startOver(captured);
  }

  void _startWithShare(ShareContent share) {
    if (!mounted) return;
    _session?.dispose();
    setState(() {
      _session = null;
      _chat = null;
      _captured = const AssistContext();
      _fromAssist = false;
      _attachText = false;
      _attachShot = false;
      _attachedImage = share.imagePath;
      _voiceInput = false;
    });
    _input.text = share.text;
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
  }

  void _startOver(AssistContext captured) {
    if (!mounted) return;
    _session?.dispose();
    setState(() {
      _session = null;
      _chat = null;
      _captured = captured;
      _fromAssist = true;
      _attachedImage = '';
      _voiceInput = false;
      _attachText =
          _storage.autoAttachScreen && captured.text.trim().isNotEmpty;
      _attachShot =
          _storage.autoAttachScreen && captured.screenshotPath.isNotEmpty;
    });
  }

  void _onChange() {
    if (!mounted) return;
    setState(() {});
    if (_scroll.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  Future<void> _send({bool fromVoice = false}) async {
    if (_listening) await _stopListening();
    final dictated = fromVoice || _voiceInput;
    _voiceInput = false;
    final text = _input.text;
    final contextText = _attachText ? _captured.text : '';
    var image = _attachedImage.isNotEmpty
        ? _attachedImage
        : (_attachShot ? _captured.screenshotPath : '');
    if (text.trim().isEmpty && image.isEmpty && contextText.isEmpty) return;

    // The capture lives in the cache folder, keep a copy with the chat
    if (image.isNotEmpty) {
      try {
        image = await persistImage(image);
      } catch (_) {
        image = '';
      }
    }

    if (_session == null) {
      final chat = await _storage.addChat(
        _storage.availableChatName('Assistant'),
      );
      if (!mounted) return;
      _chat = chat;
      _session = ChatSession(_storage, chat.id)
        ..addListener(_onChange)
        ..confirmTool = ((tool, args) async =>
            mounted ? confirmToolDialog(context, tool, args) : false)
        // The session decides whether this answer is read aloud (silent / always speak modes)
        ..onAnswer = _speak;
    }

    _input.clear();
    setState(() {
      // The screen belongs to the first message only
      _attachText = false;
      _attachShot = false;
      _attachedImage = '';
    });
    await _session!.send(
      text,
      imagePath: image,
      contextText: contextText,
      fromVoice: dictated,
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
        final value = '$_dictationBase$text';
        _input.value = TextEditingValue(
          text: value,
          selection: TextSelection.collapsed(offset: value.length),
        );
        if (text.trim().isNotEmpty) _voiceInput = true;
        if (isFinal && text.trim().isNotEmpty && _storage.autoSend) {
          _send(fromVoice: true);
        }
      },
      onError: (_) {
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
      endpoint: _storage.endpointById(
        _session?.settings.endpointId ??
            _storage.defaultChatSettings.endpointId,
      ),
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

  void _close() => SystemNavigator.pop();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final screenHeight = MediaQuery.of(context).size.height;
    final session = _session;
    final messages = session?.messages ?? const <ChatMessage>[];
    final assistantName =
        session?.settings.assistantName ??
        _storage.defaultChatSettings.assistantName;
    final screenMissing = _captured.isEmpty;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // Tapping the dimmed app behind the sheet dismisses it
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _close,
              child: const ColoredBox(color: Color(0x66000000)),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: screenHeight * 0.7),
              child: Material(
                color: scheme.surface,
                elevation: 8,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
                clipBehavior: Clip.antiAlias,
                child: SafeArea(
                  top: false,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _header(context, assistantName),
                      if (messages.isEmpty &&
                          screenMissing &&
                          _fromAssist &&
                          _session == null)
                        _hint(context),
                      if (messages.isNotEmpty)
                        Flexible(
                          child: ListView.builder(
                            controller: _scroll,
                            shrinkWrap: true,
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                            itemCount: messages.length,
                            itemBuilder: (context, i) => MessageBubble(
                              message: messages[i],
                              showReasoning: _storage.showReasoning,
                              streaming:
                                  session!.generating &&
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
                                if (text != null) {
                                  await session.editMessage(i, text);
                                }
                              },
                              onDelete: () => session.deleteMessage(i),
                              onRegenerate:
                                  i == messages.length - 1 && messages[i].isBot
                                  ? session.regenerate
                                  : null,
                            ),
                          ),
                        ),
                      if (session?.error != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 4,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.error_outline,
                                size: 18,
                                color: scheme.error,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  session!.error!,
                                  style: TextStyle(color: scheme.error),
                                  maxLines: 4,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      _chips(),
                      _inputRow(context, session),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, String name) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              name,
              style: Theme.of(context).textTheme.titleMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            tooltip: 'Open in Grace',
            icon: const Icon(Icons.open_in_full),
            onPressed: () => NativeBridge.openInMainWindow(_chat?.id),
          ),
          IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close),
            onPressed: _close,
          ),
        ],
      ),
    );
  }

  Widget _hint(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Text(
        'Grace did not receive the screen. In the system settings for the digital assistant, '
        'turn on "Use text from screen" and "Use screenshot".',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }

  Widget _chips() {
    final chips = <Widget>[
      if (_captured.text.trim().isNotEmpty)
        FilterChip(
          avatar: const Icon(Icons.article_outlined, size: 18),
          label: Text('Screen text (${_captured.text.length})'),
          selected: _attachText,
          onSelected: (v) => setState(() => _attachText = v),
        ),
      if (_captured.screenshotPath.isNotEmpty)
        FilterChip(
          avatar: const Icon(Icons.screenshot_outlined, size: 18),
          label: const Text('Screenshot'),
          selected: _attachShot,
          onSelected: (v) => setState(() => _attachShot = v),
        ),
    ];
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
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Wrap(spacing: 8, children: chips),
      ),
    );
  }

  Widget _inputRow(BuildContext context, ChatSession? session) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: MessageInput(
              controller: _input,
              autofocus: true,
              maxLines: 4,
              hint: _fromAssist ? 'Ask about this screen' : 'Ask Grace',
              onImage: (path) => setState(() => _attachedImage = path),
              onSubmitted: _send,
            ),
          ),
          IconButton(
            tooltip: _listening ? 'Stop dictation' : 'Dictate',
            onPressed: _toggleListening,
            color: _listening ? Theme.of(context).colorScheme.error : null,
            icon: Icon(_listening ? Icons.mic : Icons.mic_none),
          ),
          session?.generating == true
              ? IconButton.filledTonal(
                  tooltip: 'Stop',
                  onPressed: session!.stop,
                  icon: const Icon(Icons.stop),
                )
              : IconButton.filled(
                  tooltip: 'Send',
                  onPressed: _send,
                  icon: const Icon(Icons.send),
                ),
        ],
      ),
    );
  }
}
