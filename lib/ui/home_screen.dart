import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/native_bridge.dart';
import '../services/storage.dart';
import 'chats_screen.dart';
import 'explore_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;

  static const _pages = [ChatsScreen(), ExploreScreen(), SettingsScreen()];

  @override
  void initState() {
    super.initState();
    // Assistant gesture while the app is already running
    NativeBridge.listenForAssist(_onAssist);
    // Assistant gesture that started the app
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final pending = await NativeBridge.takePendingAssist();
      if (pending != null) _onAssist(pending);
    });
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
