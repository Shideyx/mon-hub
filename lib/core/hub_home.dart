import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'nav.dart';

/// « Revenir au menu » depuis n'importe où : ferme les pages, fenêtres et
/// boîtes ouvertes (même une page web qui garde la touche Retour) et revient
/// à l'accueil. Bouton toujours visible hors de l'accueil + Alt + Début.
class HubHome extends ChangeNotifier {
  HubHome._();
  static final instance = HubHome._();

  int _depth = 0;
  bool _inModule = false;

  /// Le squelette de l'appli revient à l'accueil (sélection vide).
  VoidCallback? onHome;

  /// Ctrl + Espace : la recherche partout (avec un texte déjà tapé).
  void Function(String text)? onSearchText;

  /// D'autres choses à fermer (fenêtre d'appel Discord…).
  final closers = <VoidCallback>[];

  /// D'autres choses ouvertes par-dessus l'appli (fenêtre d'appel…).
  final awayChecks = <bool Function()>[];

  /// On n'est pas sur l'accueil.
  bool get away => _depth > 1 || _inModule || awayChecks.any((c) => c());

  /// Pour le bouton : quelque chose a changé ailleurs (appel Discord…).
  void refresh() => _later(notifyListeners);

  late final NavigatorObserver observer = _Observer(this);

  void setInModule(bool v) {
    if (v == _inModule) return;
    _inModule = v;
    _later(notifyListeners);
  }

  void _setDepth(int d) {
    _depth = d < 0 ? 0 : d;
    _later(notifyListeners);
  }

  // Jamais pendant une construction d'écran.
  static void _later(VoidCallback f) => scheduleMicrotask(f);

  /// Retour au menu.
  void go() {
    for (final c in closers) {
      try {
        c();
      } catch (_) {}
    }
    hubNavigatorKey.currentState?.popUntil((r) => r.isFirst);
    onHome?.call();
    _later(notifyListeners);
  }
}

class _Observer extends NavigatorObserver {
  _Observer(this.home);
  final HubHome home;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => home._setDepth(home._depth + 1);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => home._setDepth(home._depth - 1);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) => home._setDepth(home._depth - 1);
}

/// Le bouton « Menu » (bord gauche de la fenêtre, déplaçable de haut en bas)
/// et le raccourci Alt + Début.
class HubHomeLayer extends StatefulWidget {
  const HubHomeLayer({super.key, required this.child, this.enabled = true});
  final Widget child;
  final bool enabled;

  @override
  State<HubHomeLayer> createState() => _HubHomeLayerState();
}

class _HubHomeLayerState extends State<HubHomeLayer> {
  double _y = 0.42;
  bool _hover = false;

  bool _onKey(KeyEvent e) {
    if (!widget.enabled || e is! KeyDownEvent) return false;
    if (e.logicalKey == LogicalKeyboardKey.home && HardwareKeyboard.instance.isAltPressed) {
      HubHome.instance.go();
      return true;
    }
    final search = HubHome.instance.onSearchText;
    // Ctrl + Espace ou Ctrl + K : la recherche (applis du PC comprises).
    final ctrlK = e.logicalKey == LogicalKeyboardKey.keyK && HardwareKeyboard.instance.isControlPressed;
    if (search != null && (ctrlK || e.logicalKey == LogicalKeyboardKey.space) && HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isAltPressed) {
      search('');
      return true;
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return Stack(
      children: [
        Positioned.fill(key: const ValueKey('home-hub'), child: widget.child),
        Positioned(
          key: const ValueKey('home-button'),
          left: 0,
          top: 0,
          bottom: 0,
          // Une bande étroite : le reste de la fenêtre reçoit les clics.
          width: 140,
          child: ListenableBuilder(
            listenable: HubHome.instance,
            builder: (context, _) {
              final show = HubHome.instance.away;
              return LayoutBuilder(
                builder: (context, box) {
                  final h = box.maxHeight;
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      AnimatedPositioned(
                        duration: const Duration(milliseconds: 260),
                        curve: Curves.easeOutCubic,
                        left: show ? 0 : -60,
                        top: (h - 64) * _y,
                        child: GestureDetector(
                          onVerticalDragUpdate: (d) =>
                              setState(() => _y = ((_y * (h - 64) + d.delta.dy) / (h - 64)).clamp(0.05, 0.95)),
                          child: MouseRegion(
                            cursor: SystemMouseCursors.click,
                            onEnter: (_) => setState(() => _hover = true),
                            onExit: (_) => setState(() => _hover = false),
                            child: _HomeTab(expanded: _hover, onTap: HubHome.instance.go),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _HomeTab extends StatelessWidget {
  const _HomeTab({required this.expanded, required this.onTap});
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: const BorderRadius.horizontal(right: Radius.circular(22)),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          height: 64,
          padding: EdgeInsets.only(left: 6, right: expanded ? 14 : 6),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [scheme.primary, Color.lerp(scheme.primary, const Color(0xFFFF5FA2), 0.45)!],
            ),
            borderRadius: const BorderRadius.horizontal(right: Radius.circular(22)),
            boxShadow: [
              BoxShadow(color: scheme.primary.withValues(alpha: expanded ? 0.45 : 0.25), blurRadius: expanded ? 18 : 8),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // La maison sautille quand la souris arrive.
              AnimatedScale(
                scale: expanded ? 1.15 : 1,
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutBack,
                child: AnimatedRotation(
                  turns: expanded ? -0.04 : 0,
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutBack,
                  child: const Icon(Icons.home_rounded, color: Colors.white, size: 22),
                ),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                child: expanded
                    ? const Padding(
                        padding: EdgeInsets.only(left: 6),
                        child: Text('Menu', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
