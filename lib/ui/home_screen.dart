import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/native_bridge.dart';
import '../services/storage.dart';
import '../services/wake_word_service.dart';
import 'chats_screen.dart';
import 'explore_screen.dart';
import 'settings_screen.dart';
import 'voice_target.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  int _index = 0;

  late final Storage _storage;
  late final WakeWordService _wakeWord;
  bool _foreground = true;

  static const _pages = [ChatsScreen(), ExploreScreen(), SettingsScreen()];

  @override
  void initState() {
    super.initState();
    _storage = context.read<Storage>();
    _wakeWord = WakeWordService(onDetected: _onWakeWord);
    _storage.addListener(_syncWakeWord);
    _syncWakeWord();
    // Assistant gesture while the app is already running
    NativeBridge.listen(onAssist: _onAssist, onOpenChat: _openChatById);
    WidgetsBinding.instance.addObserver(this);
    // Assistant gesture that started the app
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final pending = await NativeBridge.takePendingAssist();
      if (pending != null) _onAssist(pending);
      final chatId = await NativeBridge.takePendingChatId();
      if (chatId != null) _openChatById(chatId);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _storage.removeListener(_syncWakeWord);
    unawaited(_wakeWord.stop());
    super.dispose();
  }

  // The assistant overlay may have changed chats while this window was in the background
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _storage.reload();

    // The microphone is only used while Grace is on screen. `inactive` also happens behind
    // the permission dialog, which must not end the listening that asked for it.
    if (state == AppLifecycleState.resumed) {
      _foreground = true;
      _syncWakeWord();
    } else if (state == AppLifecycleState.paused) {
      _foreground = false;
      _syncWakeWord();
    }
  }

  /// Starts or stops the wake word to match the setting and whether Grace is on screen.
  void _syncWakeWord() {
    final wanted = _storage.wakeWordEnabled && _foreground;
    if (wanted == _wakeWord.running) return;

    if (!wanted) {
      unawaited(_wakeWord.stop());
      return;
    }

    unawaited(() async {
      final started = await _wakeWord.start();
      if (!started && mounted && _storage.wakeWordEnabled && _foreground) {
        // No microphone permission, or the models did not load: turn the setting off
        // instead of failing silently on every start
        await _storage.setWakeWordEnabled(false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'The wake word could not start. Check the microphone permission.',
              ),
            ),
          );
        }
      }
    }());
  }

  /// A chat that is open takes the request, otherwise a new chat opens.
  void _onWakeWord() {
    if (!mounted) return;
    final target = VoiceTargets.current;
    if (target != null && target.canStartVoice) {
      unawaited(target.startVoice('wakeword'));
      return;
    }
    unawaited(_onAssist(const AssistContext(trigger: 'wakeword')));
  }

  Future<void> _openChatById(String chatId) async {
    if (!mounted) return;
    final storage = context.read<Storage>();
    await storage.reload();
    if (!mounted) return;
    final chat = storage.chats.where((c) => c.id == chatId).firstOrNull;
    if (chat == null) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    openChat(context, chat);
  }

  /// Opens a new chat with the captured screen attached.
  Future<void> _onAssist(AssistContext captured) async {
    if (!mounted) return;
    final storage = context.read<Storage>();
    final info = await storage.addChat(storage.availableChatName('Assistant'));
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    openChat(context, info, assist: captured);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: 'Chats',
          ),
          NavigationDestination(
            icon: Icon(Icons.explore_outlined),
            selectedIcon: Icon(Icons.explore),
            label: 'Explore',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
