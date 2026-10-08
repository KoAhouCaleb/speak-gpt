import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'services/app_http.dart';
import 'services/storage.dart';
import 'theme.dart';
import 'ui/assist_overlay.dart';
import 'ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppHttp.init();
  final storage = await Storage.open();
  runApp(
    ChangeNotifierProvider<Storage>.value(
      value: storage,
      child: const GraceApp(),
    ),
  );
}

/// Entry point of the assistant overlay. Android starts it in its own engine for
/// AssistOverlayActivity (see getDartEntrypointFunctionName there).
@pragma('vm:entry-point')
Future<void> assistOverlayMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppHttp.init();
  final storage = await Storage.open();
  runApp(
    ChangeNotifierProvider<Storage>.value(
      value: storage,
      child: const AssistOverlayApp(),
    ),
  );
}

class GraceApp extends StatelessWidget {
  const GraceApp({super.key});

  @override
  Widget build(BuildContext context) {
    final storage = context.watch<Storage>();

    return MaterialApp(
      title: 'Grace',
      debugShowCheckedModeBanner: false,
      theme: lightTheme(),
      darkTheme: darkTheme(amoled: storage.amoled),
      themeMode: themeModeOf(storage),
      home: const HomeScreen(),
    );
  }
}
