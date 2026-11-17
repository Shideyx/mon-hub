import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:material_ui/material_ui.dart';

import '../core/windows_look.dart';

/// Le thème de Mon Hub, façon **Windows 11** (Fluent) : police Segoe UI
/// Variable, fond « Mica » gris clair / gris foncé, cartes blanches ou
/// grises bordées d'un trait fin, coins arrondis discrets, et la couleur
/// d'accent choisie dans Windows.
ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final windows = !kIsWeb && Platform.isWindows;
  final accent = windows ? WindowsLook.accent : const Color(0xFF0067C0);
  // En mode sombre, Windows éclaircit l'accent pour qu'il reste lisible.
  final primary = dark ? Color.lerp(accent, Colors.white, 0.45)! : accent;
  final background = WindowsLook.background(brightness);
  final card = dark ? const Color(0xFF2B2B2B) : Colors.white;
  final stroke = dark ? const Color(0x14FFFFFF) : const Color(0x0F000000);
  final scheme = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
  ).copyWith(
    primary: primary,
    onPrimary: dark ? Colors.black : Colors.white,
    surface: background,
    onSurface: dark ? Colors.white : const Color(0xFF1B1B1B),
    surfaceContainerLowest: card,
    surfaceContainerLow: card,
    surfaceContainer: dark ? const Color(0xFF272727) : const Color(0xFFF9F9F9),
    surfaceContainerHigh: dark ? const Color(0xFF2D2D2D) : const Color(0xFFFBFBFB),
    surfaceContainerHighest: dark ? const Color(0xFF333333) : const Color(0xFFEDEDED),
    outlineVariant: dark ? const Color(0xFF3A3A3A) : const Color(0xFFE5E5E5),
  );
  const small = BorderRadius.all(Radius.circular(4));
  const medium = BorderRadius.all(Radius.circular(8));
  final base = ThemeData(useMaterial3: true, brightness: brightness);
  final text = base.textTheme
      .apply(
        fontFamily: windows ? 'Segoe UI Variable Text' : null,
        fontFamilyFallback: windows ? const ['Segoe UI', 'Segoe UI Emoji', 'Segoe UI Symbol'] : null,
        bodyColor: scheme.onSurface,
        displayColor: scheme.onSurface,
      )
      .copyWith(
        headlineMedium: base.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w600, letterSpacing: 0),
        titleLarge: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600, letterSpacing: 0),
      );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    textTheme: text.apply(
      fontFamily: windows ? 'Segoe UI Variable Text' : null,
      fontFamilyFallback: windows ? const ['Segoe UI', 'Segoe UI Emoji', 'Segoe UI Symbol'] : null,
    ),
    scaffoldBackgroundColor: background,
    canvasColor: background,
    visualDensity: windows ? VisualDensity.compact : VisualDensity.standard,
    splashFactory: windows ? NoSplash.splashFactory : null,
    hoverColor: (dark ? Colors.white : Colors.black).withValues(alpha: 0.04),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 1, space: 1),
    appBarTheme: AppBarTheme(
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontFamily: windows ? 'Segoe UI Variable Display' : null,
        fontFamilyFallback: windows ? const ['Segoe UI'] : null,
        fontSize: 22,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: card,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: medium, side: BorderSide(color: stroke)),
      margin: EdgeInsets.zero,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? const Color(0x0FFFFFFF) : Colors.white,
      border: OutlineInputBorder(borderRadius: small, borderSide: BorderSide(color: scheme.outlineVariant)),
      enabledBorder: OutlineInputBorder(borderRadius: small, borderSide: BorderSide(color: scheme.outlineVariant)),
      focusedBorder: OutlineInputBorder(borderRadius: small, borderSide: BorderSide(color: primary, width: 2)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: dark ? const Color(0xFF2B2B2B) : const Color(0xFFF9F9F9),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: medium, side: BorderSide(color: stroke)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: dark ? const Color(0xFF2C2C2C) : const Color(0xFFF9F9F9),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: medium, side: BorderSide(color: stroke)),
    ),
    listTileTheme: const ListTileThemeData(shape: RoundedRectangleBorder(borderRadius: small)),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: small),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: const RoundedRectangleBorder(borderRadius: small),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: const RoundedRectangleBorder(borderRadius: small),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(shape: const RoundedRectangleBorder(borderRadius: small)),
    ),
    segmentedButtonTheme: const SegmentedButtonThemeData(
      style: ButtonStyle(shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: small))),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: small, side: BorderSide(color: scheme.outlineVariant)),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF2C2C2C) : const Color(0xFFF9F9F9),
        borderRadius: small,
        border: Border.all(color: stroke),
      ),
      textStyle: TextStyle(color: scheme.onSurface, fontSize: 12),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: dark ? const Color(0xFF1C1C1C) : const Color(0xFFEEEEEE),
      indicatorColor: primary.withValues(alpha: 0.18),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: FadeForwardsPageTransitionsBuilder(),
      },
    ),
  );
}
