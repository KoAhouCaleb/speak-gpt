import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'services/storage.dart';
import 'ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final storage = await Storage.open();
  runApp(
    ChangeNotifierProvider<Storage>.value(
      value: storage,
      child: const GraceApp(),
    ),
  );
}

class GraceApp extends StatelessWidget {
  const GraceApp({super.key});

  static const _seed = Color(0xFF3F6BC9);

  @override
  Widget build(BuildContext context) {
    final storage = context.watch<Storage>();

    final light = ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: _seed),
      useMaterial3: true,
    );
    var darkScheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: Brightness.dark,
    );
    if (storage.amoled) darkScheme = darkScheme.copyWith(surface: Colors.black);
    final dark = ThemeData(
      colorScheme: darkScheme,
      useMaterial3: true,
      scaffoldBackgroundColor: storage.amoled ? Colors.black : null,
    );

    return MaterialApp(
      title: 'Grace',
      debugShowCheckedModeBanner: false,
      theme: light,
      darkTheme: dark,
      themeMode: switch (storage.themeMode) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      },
      home: const HomeScreen(),
    );
  }
}
