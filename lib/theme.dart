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

/// MaterialApp builder that scales text linearly with the system font size.
///
/// On Android 14 and newer Flutter asks the engine for every scaled font size, and the engine
/// keeps the data for that in a queue shared by all Flutter engines of the process. Grace runs
/// the compact assistant in a second engine, and once that has been used the main window can
/// ask for data the other engine already discarded ("incorrect configuration id", a red screen
/// in debug builds). Reading the plain scale factor avoids the lookup. The only difference is
/// that Android 14's gentler scaling of large text is not applied.
Widget linearTextScale(BuildContext context, Widget? child) {
  // ignore: deprecated_member_use
  final factor = WidgetsBinding.instance.platformDispatcher.textScaleFactor;
  return MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(factor)),
    child: child ?? const SizedBox.shrink(),
  );
}

ThemeMode themeModeOf(Storage storage) => switch (storage.themeMode) {
  'light' => ThemeMode.light,
  'dark' => ThemeMode.dark,
  _ => ThemeMode.system,
};
