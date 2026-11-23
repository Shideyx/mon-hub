import 'package:material_ui/material_ui.dart';

import 'hud/hud.dart';
import 'motion.dart';

const _seed = Color(0xFF7C5CFF);

/// Le thème de Mon Hub : violet et rose (comme toujours), en version « HUD »
/// (v1.60) — coins coupés, boutons penchés, titres en police technique.
ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final h = dark ? HudColors.dark : HudColors.light;
  final scheme = ColorScheme.fromSeed(
    seedColor: _seed,
    brightness: brightness,
    surface: h.bg,
  ).copyWith(
    primary: h.accent,
    secondary: h.pink,
    surfaceContainerLowest: h.panelLow,
    surfaceContainerLow: h.panelLow,
    surfaceContainer: h.panel,
    surfaceContainerHigh: dark ? const Color(0xFF1A1C27) : const Color(0xFFF1EFF8),
    surfaceContainerHighest: dark ? const Color(0xFF1F2131) : const Color(0xFFE9E6F3),
    outlineVariant: h.line,
    outline: dark ? const Color(0xFF4A4E6A) : const Color(0xFFB5AFD6),
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, brightness: brightness);
  // Titres en Chakra Petch ; le texte courant garde la police du système
  // (plus lisible pour lire longtemps).
  TextStyle? display(TextStyle? s, {FontWeight w = FontWeight.w700}) =>
      s?.copyWith(fontFamily: HudFonts.display, fontWeight: w, letterSpacing: 0.3);
  final text = base.textTheme.copyWith(
    displayLarge: display(base.textTheme.displayLarge),
    displayMedium: display(base.textTheme.displayMedium),
    displaySmall: display(base.textTheme.displaySmall),
    headlineLarge: display(base.textTheme.headlineLarge),
    headlineMedium: display(base.textTheme.headlineMedium),
    headlineSmall: display(base.textTheme.headlineSmall),
    titleLarge: display(base.textTheme.titleLarge),
    titleMedium: display(base.textTheme.titleMedium, w: FontWeight.w600),
  );
  const slant = SlantBorder(slant: 9);
  final cut = hudCut(14, side: BorderSide(color: h.line));
  return base.copyWith(
    scaffoldBackgroundColor: h.bg,
    canvasColor: h.bg,
    textTheme: text,
    visualDensity: VisualDensity.standard,
    appBarTheme: AppBarTheme(
      backgroundColor: h.bg,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontFamily: HudFonts.display,
        fontSize: 22,
        fontWeight: FontWeight.w700,
        color: h.text,
        letterSpacing: 0.4,
      ),
    ),
    cardTheme: CardThemeData(elevation: 0, color: h.panel, shape: cut, margin: EdgeInsets.zero),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: h.panelLow,
      // Seulement « border » : sa couleur suit l'état (violet quand on écrit),
      // et un champ qui dit « pas de bord » (InputBorder.none) le reste.
      border: const OutlineInputBorder(borderRadius: BorderRadius.zero),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    ),
    dialogTheme: DialogThemeData(backgroundColor: h.panel, shape: hudCut(18, side: BorderSide(color: h.hotLine))),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: h.panel,
      shape: const BeveledRectangleBorder(borderRadius: BorderRadius.only(topRight: Radius.circular(18))),
    ),
    popupMenuTheme: PopupMenuThemeData(color: h.panel, shape: hudCut(10, side: BorderSide(color: h.line))),
    listTileTheme: const ListTileThemeData(shape: BeveledRectangleBorder(borderRadius: BorderRadius.only(topRight: Radius.circular(8)))),
    chipTheme: base.chipTheme.copyWith(shape: const SlantBorder(slant: 7), side: BorderSide(color: h.line)),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating, shape: slant),
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(shape: slant)),
    elevatedButtonTheme: ElevatedButtonThemeData(style: ElevatedButton.styleFrom(shape: slant)),
    outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(shape: slant)),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(shape: slant)),
    segmentedButtonTheme: SegmentedButtonThemeData(style: SegmentedButton.styleFrom(shape: const BeveledRectangleBorder())),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: h.side,
      indicatorColor: h.selected,
      indicatorShape: slant,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: dark ? const Color(0xFF242638) : const Color(0xFF2A2840)),
      textStyle: const TextStyle(color: Colors.white, fontSize: 12),
    ),
    dividerTheme: DividerThemeData(color: h.line, space: 1),
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
