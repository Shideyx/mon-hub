import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/module_store.dart';
import '../../core/web_notify.dart';
import '../discord/discord_phone.dart' show DiscordPhone;

/// Les messages Instagram **tout de suite**, sans rien demander à Instagram.
///
/// Le vrai instagram.com (tes messages) reste ouvert, caché derrière Mon Hub,
/// exactement comme un onglet de navigateur laissé ouvert : c'est la page
/// d'Instagram elle-même qui reçoit tes messages en direct. Mon Hub regarde
/// seulement son titre (« (2) Instagram » = 2 conversations non lues) et les
/// notifications qu'elle voudrait afficher.
///
/// ⚠️ Toujours **aucune** requête automatique, aucune API privée, aucun envoi
/// (c'est ce qui avait fait bloquer le compte avant la v1.42) : rien de plus
/// qu'un onglet ouvert.
class InstagramWatch extends ChangeNotifier {
  InstagramWatch._();
  static final instance = InstagramWatch._();

  static const inbox = 'https://www.instagram.com/direct/inbox/';

  /// Sur Windows seulement (WebView2).
  static bool get supported => !kIsWeb && Platform.isWindows;

  /// Seule la fenêtre principale de Mon Hub la garde ouverte.
  static bool allowed = false;

  /// Réglage propre au PC : « Messages Instagram en direct » (oui par défaut).
  static const prefKey = 'app.instagram.direct';
  static bool get wanted {
    try {
      return ModuleStore.global.getBool(prefKey) ?? true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> setWanted(bool on) async {
    await ModuleStore.global.setBool(prefKey, on);
    on ? instance.start() : instance.stop();
  }

  /// La page cachée existe.
  bool active = false;

  /// Instagram n'est pas connecté dans Mon Hub (page de connexion).
  bool loggedOut = false;

  /// Conversations non lues (d'après le titre de la page).
  int unread = 0;

  /// Du nouveau : [news] dit combien de non-lus, et ce que la notification
  /// d'Instagram disait (si elle en a montré une). Branché par Mon Hub.
  void Function(WebNews news)? onNews;

  /// Le nombre de non-lus change (pastille du module). Branché par Mon Hub.
  void Function(int unread)? onUnread;

  InAppWebViewController? _c;
  Timer? _watch;
  bool _measured = false;
  int? _count;
  int _relayed = 0;
  DateTime? _reloadedAt;

  /// Remplace la vraie page (tests).
  @visibleForTesting
  static WidgetBuilder? testWebView;

  void start() {
    if (!supported || !allowed || active || !wanted) return;
    active = true;
    notifyListeners();
  }

  void stop() {
    _watch?.cancel();
    _watch = null;
    _c = null;
    _measured = false;
    active = false;
    notifyListeners();
  }

  /// Recharge la page (après une connexion faite dans la page Instagram).
  Future<void> reload() async {
    _measured = false;
    _reloadedAt = DateTime.now();
    await _c?.loadUrl(urlRequest: URLRequest(url: WebUri(inbox)));
  }

  @visibleForTesting
  void attach(InAppWebViewController c) {
    _c = c;
    _measured = false;
    _watch?.cancel();
    // Toutes les 3 s : un coup d'œil au titre (rien n'est demandé au site).
    _watch = Timer.periodic(const Duration(seconds: 3), (_) => unawaited(check()));
  }

  bool _checking = false;

  Future<void> check() async {
    final c = _c;
    if (c == null || _checking) return;
    _checking = true;
    try {
      // Caché : rien à dessiner (comme le Discord caché).
      final r = await c.evaluateJavascript(
        source: '${DiscordPhone.quietScript(true)}\n${WebNotify.statusScript(loginPattern: r'^/(accounts|challenge)/')}',
      );
      if (r is! String) return;
      onStatus((jsonDecode(r) as Map).cast<String, dynamic>());
    } catch (_) {
    } finally {
      _checking = false;
    }
  }

  /// Applique ce que la page montre (séparé pour les tests).
  @visibleForTesting
  void onStatus(Map<String, dynamic> j) {
    final out = j['loggedOut'] == true;
    if (out != loggedOut) {
      loggedOut = out;
      notifyListeners();
    }
    if (out) {
      // Pas connecté : on retente de temps en temps (tu t'es peut-être
      // connecté dans la page Instagram de Mon Hub entre-temps).
      final last = _reloadedAt;
      if (last == null || DateTime.now().difference(last) > const Duration(minutes: 10)) unawaited(reload());
      return;
    }
    final title = '${j['title'] ?? ''}'.trim();
    final count = WebNotify.countInTitle(title) ?? (title.toLowerCase().contains('instagram') ? 0 : null);
    final relayed = (j['n'] as num?)?.toInt() ?? _relayed;
    final last = j['last'] is Map ? (j['last'] as Map).cast<String, dynamic>() : null;
    final news = _measured
        ? WebNotify.news(before: _count, now: count, notifsBefore: _relayed, notifsNow: relayed, last: last)
        : null;
    _measured = true;
    if (count != null && count != unread) {
      unread = count;
      onUnread?.call(count);
      notifyListeners();
    }
    _count = count ?? _count;
    _relayed = relayed;
    if (news != null) onNews?.call(news);
  }

  /// La notification à montrer pour [news]. Sans navigateur : testable.
  static (String, String) describe(WebNews news) {
    if (news.title.isNotEmpty) {
      return ('📸 ${news.title}', news.body.isEmpty ? 'Nouveau message sur Instagram' : news.body);
    }
    final n = news.count;
    return (
      '📸 Instagram',
      n <= 1 ? 'Tu as un nouveau message.' : 'Tu as $n conversations non lues.',
    );
  }
}

/// La page Instagram cachée derrière Mon Hub (posée dans le builder de
/// `HubApp`, à côté du Discord caché). Jamais affichée.
class InstagramWatchLayer extends StatelessWidget {
  const InstagramWatchLayer({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final w = InstagramWatch.instance;
    return ListenableBuilder(
      listenable: w,
      builder: (context, _) => Stack(
        children: [
          // Toujours à la même place, avec sa clé : Mon Hub n'est jamais
          // reconstruit quand la page cachée apparaît ou disparaît.
          if (w.active)
            Positioned(
              key: const ValueKey('insta-web'),
              left: 0,
              top: 0,
              width: 420,
              height: 640,
              child: InstagramWatch.testWebView?.call(context) ?? const _WatchWebView(),
            ),
          Positioned.fill(key: const ValueKey('insta-hub'), child: child),
        ],
      ),
    );
  }
}

class _WatchWebView extends StatelessWidget {
  const _WatchWebView();

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(InstagramWatch.inbox)),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        thirdPartyCookiesEnabled: true,
        domStorageEnabled: true,
        databaseEnabled: true,
        // Jamais de son ni de vidéo qui se lance en fond.
        mediaPlaybackRequiresUserGesture: true,
      ),
      initialUserScripts: UnmodifiableListView([
        UserScript(source: WebNotify.shimScript, injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START),
      ]),
      onWebViewCreated: InstagramWatch.instance.attach,
      // Ni micro ni caméra pour la page cachée.
      onPermissionRequest: (_, req) async =>
          PermissionResponse(resources: req.resources, action: PermissionResponseAction.DENY),
    ),
  );
}
