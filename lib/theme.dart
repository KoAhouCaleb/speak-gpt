import 'package:flutter/material.dart';

import 'services/storage.dart';

const _seed = Color(0xFF3F6BC9);

ThemeData lightTheme() => ThemeData(
  colorScheme: ColorScheme.fromSeed(seedColor: _seed),
  useMaterial3: true,
);

ThemeData darkTheme({required bool amoled}) {
  var scheme = ColorScheme.fromSeed(
    seedColor: _seed,
    brightness: Brightness.dark,
  );
  if (amoled) scheme = scheme.copyWith(surface: Colors.black);
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: amoled ? Colors.black : null,
  );
}

ThemeMode themeModeOf(Storage storage) => switch (storage.themeMode) {
  'light' => ThemeMode.light,
  'dark' => ThemeMode.dark,
  _ => ThemeMode.system,
};
