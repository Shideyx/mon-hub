import 'package:material_ui/material_ui.dart';

import 'motion.dart';

const _seed = Color(0xFF7C5CFF);

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: _seed,
    brightness: brightness,
    surface: dark ? const Color(0xFF0E0F14) : const Color(0xFFF6F5FB),
  );
  final radius = BorderRadius.circular(16);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    visualDensity: VisualDensity.standard,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
          fontSize: 22, fontWeight: FontWeight.w700, color: scheme.onSurface, letterSpacing: -0.3),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: dark ? const Color(0xFF181A22) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: dark ? 0.35 : 0.5)),
      ),
      margin: EdgeInsets.zero,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      border: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide.none),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    ),
    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
    ),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(borderRadius: radius),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: radius),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: radius)),
    ),
    // Pages qui glissent en douceur, façon Spotify.
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: SpotifyPageTransitionsBuilder(),
      TargetPlatform.windows: SpotifyPageTransitionsBuilder(),
      TargetPlatform.linux: SpotifyPageTransitionsBuilder(),
      TargetPlatform.macOS: SpotifyPageTransitionsBuilder(),
      TargetPlatform.iOS: SpotifyPageTransitionsBuilder(),
    }),
  );
}
