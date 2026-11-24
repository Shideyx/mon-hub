import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/cam_blur.dart';
import '../../core/notifications.dart';
import '../../core/web_notify.dart';
import '../../ui/call_page.dart';

/// Ce que fait le « téléphone » Discord.
enum PhoneState { off, starting, ready, ringing, calling, inCall }

/// Les appels Discord **dans Mon Hub**, sans navigateur : le Discord
/// officiel (discord.com, ton compte déjà connecté dans Mon Hub) reste
/// ouvert, caché derrière l'appli. Quand on t'appelle, Mon Hub sonne et
/// affiche « Répondre / Refuser » ; l'appel se passe dans une fenêtre de
/// Mon Hub, avec ton micro et ta caméra.
///
/// C'est le vrai Discord qui gère l'appel (le son est chiffré de bout en
/// bout par Discord) : Mon Hub ne fait qu'appuyer sur ses boutons.
class DiscordPhone extends ChangeNotifier {
  DiscordPhone._();
  static final instance = DiscordPhone._();

  static const home = 'https://discord.com/channels/@me';

  /// Le Discord caché marche sur Windows (WebView2 d'Edge).
  static bool get supported => !kIsWeb && Platform.isWindows;

  /// Seule la fenêtre principale de Mon Hub garde Discord ouvert (pas
  /// Nexo partout, ni les widgets du bureau).
  static bool allowed = false;

  /// Le Discord caché existe (il tourne en fond).
  bool active = false;

  /// La fenêtre de Discord est affichée par-dessus Mon Hub.
  bool shown = false;

  PhoneState state = PhoneState.off;

  /// Qui appelle (ou avec qui on est en appel).
  String who = '';

  /// Discord n'est pas connecté dans le navigateur intégré.
  bool loggedOut = false;

  /// Pour annoncer un appel (bandeau + notification de Windows).
  NotificationCenter? notifications;

  /// Un nouveau message vient d'arriver dans le vrai Discord (son titre
  /// compte un non-lu de plus, ou il a voulu montrer une notification) :
  /// Mon Hub relève Discord **tout de suite** au lieu d'attendre 2 minutes.
  /// Branché par Mon Hub.
  void Function()? onActivity;

  bool _measured = false;
  int? _unread;
  int _relayed = 0;
  DateTime? _lastActivity;
  Timer? _activityTimer;

  InAppWebViewController? _c;
  Timer? _watch;

  /// Remplace la vraie page Discord (tests).
  @visibleForTesting
  static WidgetBuilder? testWebView;

  /// Allume le téléphone sans Windows (tests).
  @visibleForTesting
  void forceActive({PhoneState state = PhoneState.ready}) {
    active = true;
    this.state = state;
    notifyListeners();
  }

  bool _checking = false;

  void _set(PhoneState s, {String? who}) {
    final changed = s != state || (who != null && who != this.who);
    state = s;
    if (who != null) this.who = who;
    if (changed) notifyListeners();
  }

  /// Ouvre le Discord caché (s'il n'est pas déjà ouvert).
  void start() {
    if (!supported || !allowed || active) return;
    active = true;
    _set(PhoneState.starting);
    notifyListeners();
  }

  /// Ferme le Discord caché (plus d'appels reçus dans Mon Hub).
  void stop() {
    _watch?.cancel();
    _watch = null;
    _activityTimer?.cancel();
    _activityTimer = null;
    _measured = false;
    _c = null;
    CamBlur.instance.apply = null;
    active = false;
    shown = false;
    _set(PhoneState.off, who: '');
    notifyListeners();
  }

  void show() {
    if (!active) start();
    if (!active) return;
    shown = true;
    unawaited(_js(quietScript(false)));
    notifyListeners();
  }

  void hide() {
    shown = false;
    unawaited(_js(quietScript(true)));
    notifyListeners();
  }

  /// Appelé par la vue cachée quand Discord est prêt.
  @visibleForTesting
  void attach(InAppWebViewController c) {
    _c = c;
    _measured = false;
    _unread = null;
    _relayed = 0;
    // Le flou de la caméra se change en plein appel.
    CamBlur.instance.apply = (js) async {
      await _js(js);
      final r = await _js('window.__monhubFlouEtat ? window.__monhubFlouEtat() : ""');
      try {
        final j = jsonDecode('$r');
        if (j is Map && (j['pistes'] as num? ?? 0) > 0) CamBlur.instance.faceDetection = j['visage'] == true;
      } catch (_) {}
    };
    _watch?.cancel();
    _watch = Timer.periodic(const Duration(seconds: 2), (_) => unawaited(check()));
  }

  Future<Object?> _js(String source) async {
    final c = _c;
    if (c == null) return null;
    try {
      return await c.evaluateJavascript(source: source);
    } catch (_) {
      return null;
    }
  }

  /// Regarde l'état de Discord : est-ce que ça sonne ? un appel est-il en
  /// cours ?
  Future<void> check() async {
    if (_checking) return;
    _checking = true;
    try {
      // Caché derrière Mon Hub, Discord ne dessine plus rien (avant : il se
      // redessinait sans arrêt en arrière-plan et faisait ramer l'appli).
      final r = await _js('${quietScript(!shown)}\n$statusScript');
      if (r is! String) return;
      final j = (jsonDecode(r) as Map).cast<String, dynamic>();
      onStatus(j);
    } catch (_) {
    } finally {
      _checking = false;
    }
  }

  /// Applique l'état lu dans Discord (séparé pour les tests).
  @visibleForTesting
  void onStatus(Map<String, dynamic> j) {
    final out = j['loggedOut'] == true;
    if (out != loggedOut) {
      loggedOut = out;
      notifyListeners();
    }
    // Du nouveau dans Discord ? (non-lus du titre, notification relayée)
    final unread = WebNotify.countInTitle('${j['title'] ?? ''}');
    final relayed = (j['n'] as num?)?.toInt() ?? _relayed;
    final news = !_measured
        ? null // premier regard : on prend juste la mesure
        : WebNotify.news(before: _unread, now: unread, notifsBefore: _relayed, notifsNow: relayed);
    _measured = true;
    _unread = unread;
    _relayed = relayed;
    if (news != null) _activity();
    final ringing = j['ringing'] == true;
    final inCall = j['inCall'] == true;
    final name = '${j['who'] ?? ''}'.trim();
    if (ringing) {
      if (state != PhoneState.ringing) {
        _set(PhoneState.ringing, who: name);
        _announce(name);
      }
      return;
    }
    if (inCall) {
      _set(PhoneState.inCall, who: state == PhoneState.ringing || who.isNotEmpty ? who : name);
      return;
    }
    // L'appel qu'on lance met quelques secondes à démarrer.
    if (state == PhoneState.calling) return;
    if (state == PhoneState.ringing || state == PhoneState.inCall || state == PhoneState.starting) {
      _set(PhoneState.ready, who: '');
    }
  }

  /// Relève Discord tout de suite (au plus une fois toutes les 3 s : une
  /// rafale de messages = une seule relève).
  void _activity() {
    final now = DateTime.now();
    final last = _lastActivity;
    if (last == null || now.difference(last) >= const Duration(seconds: 3)) {
      _lastActivity = now;
      onActivity?.call();
      return;
    }
    _activityTimer ??= Timer(const Duration(seconds: 3), () {
      _activityTimer = null;
      _lastActivity = DateTime.now();
      onActivity?.call();
    });
  }

  void _announce(String name) {
    final n = notifications;
    if (n == null) return;
    unawaited(
      n.post(
        HubNotification(
          id: 'discord-appel-${DateTime.now().millisecondsSinceEpoch}',
          title: 'Appel Discord',
          body: name.isEmpty ? 'On t\'appelle sur Discord' : '$name t\'appelle',
          moduleId: 'discord',
        ),
      ),
    );
  }

  /// Répond à l'appel qui sonne (et affiche la fenêtre d'appel).
  Future<bool> answer({bool video = false}) async {
    final ok = await _js(buttonScript(video ? 'answerVideo' : 'answer')) == true;
    if (ok) {
      shown = true;
      _set(PhoneState.inCall);
      notifyListeners();
    }
    return ok;
  }

  /// Refuse l'appel qui sonne.
  Future<bool> decline() async {
    final ok = await _js(buttonScript('decline')) == true;
    if (ok) _set(PhoneState.ready, who: '');
    return ok;
  }

  /// Raccroche (appel ou salon vocal).
  Future<bool> hangUp() async {
    final ok = await _js(buttonScript('hangup')) == true;
    if (ok) {
      shown = false;
      _set(PhoneState.ready, who: '');
      notifyListeners();
    }
    return ok;
  }

  /// Va sur une page de Discord sans tout recharger.
  Future<void> _go(String path) async {
    await _js(navigateScript(path));
  }

  /// Appelle quelqu'un (conversation privée [channelId]).
  Future<bool> call(String channelId, {bool video = false, String title = ''}) =>
      _press('/channels/@me/$channelId', CallPage.clickScript(video: video), title);

  /// Rejoint un salon vocal d'un serveur.
  Future<bool> joinVoice(String guildId, String channelId, {String title = ''}) =>
      _press('/channels/$guildId/$channelId', buttonScript('joinVoice'), title);

  /// Ouvre une page de Discord et appuie sur un bouton dès qu'il apparaît.
  Future<bool> _press(String path, String script, String title) async {
    show();
    _set(PhoneState.calling, who: title);
    for (var i = 0; i < 40 && _c == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    await _go(path);
    for (var i = 0; i < 16; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      if (await _js(script) == true) {
        _set(PhoneState.inCall, who: title);
        return true;
      }
      // Discord n'a pas changé de page tout seul : on recharge à la bonne
      // adresse.
      if (i == 5) {
        await _c?.loadUrl(urlRequest: URLRequest(url: WebUri('https://discord.com$path')));
      }
    }
    _set(PhoneState.ready);
    return false;
  }

  /// Va sur une adresse de Discord sans recharger toute l'appli.
  static String navigateScript(String path) =>
      '''
(function (p) {
  if (location.pathname !== p) {
    history.pushState(null, '', p);
    window.dispatchEvent(new PopStateEvent('popstate', { state: null }));
  }
  return location.pathname;
})(${jsonEncode(path)});
''';

  /// Mots des boutons de Discord (français et anglais).
  static const _accept = r"^(accepter|accept|répondre|answer|rejoindre l'appel|join call|rejoindre avec|join with)";
  static const _video = r'(vidéo|video)';
  static const _decline = r'^(refuser|decline|ignorer|ignore)';
  static const _hangup = r"(déconnecter|déconnexion|disconnect|raccrocher|hang up|quitter l'appel|leave call)";
  static const _joinVoice = r'(rejoindre le (salon )?vocal|join voice)';
  static const _callWords = r'(appel|call|sonne|ring)';

  static const _helpers =
      '''
  function vis(e) { var r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; }
  function lab(e) { return ((e.getAttribute && e.getAttribute('aria-label')) || e.textContent || '').trim(); }
  function buttons(root) {
    return [].slice.call((root || document).querySelectorAll('button, [role="button"]')).filter(vis);
  }
  var ACC = new RegExp("$_accept", "i"), VID = new RegExp("$_video", "i"),
      DEC = new RegExp("$_decline", "i"), HANG = new RegExp("$_hangup", "i"),
      JOIN = new RegExp("$_joinVoice", "i"), CALL = new RegExp("$_callWords", "i");
  // La fenêtre d'appel entrant : un bouton « Refuser » et un bouton
  // « Accepter » côte à côte, qui parlent d'appel (pas une demande d'ami).
  function ringBox() {
    var bs = buttons();
    for (var i = 0; i < bs.length; i++) {
      if (!DEC.test(lab(bs[i]))) continue;
      var box = bs[i];
      for (var k = 0; k < 7 && box; k++) {
        box = box.parentElement;
        if (!box) break;
        var acc = buttons(box).filter(function (x) { return ACC.test(lab(x)); });
        if (acc.length && (CALL.test(box.textContent || '') || acc.some(function (x) { return CALL.test(lab(x)); }))) {
          return box;
        }
      }
    }
    return null;
  }
''';

  /// Rend Discord invisible et immobile (rien à dessiner) quand il est caché.
  /// Les boutons restent là : on peut toujours répondre ou raccrocher.
  static String quietScript(bool quiet) =>
      '''
(function (q) {
  var s = document.getElementById('mh-quiet');
  if (q && !s) {
    s = document.createElement('style');
    s.id = 'mh-quiet';
    s.textContent = '*,*::before,*::after{visibility:hidden!important;animation-play-state:paused!important;transition:none!important}';
    (document.head || document.documentElement).appendChild(s);
  }
  if (!q && s) s.remove();
})($quiet);
''';

  /// Lit l'état de Discord (en JSON).
  static String get statusScript =>
      '''
(function () {
$_helpers
  // Le nom de la personne : le premier texte hors des boutons, autour de
  // la fenêtre d'appel.
  function nameNear(el) {
    for (var k = 0; k < 4 && el; k++, el = el.parentElement) {
      var w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT), n;
      while ((n = w.nextNode())) {
        var t = (n.nodeValue || '').trim();
        if (t.length < 2) continue;
        var p = n.parentElement;
        if (p && p.closest('button, [role="button"]')) continue;
        if (/^(appel|incoming|call|sonne|ring)/i.test(t) || ACC.test(t) || DEC.test(t)) continue;
        return t;
      }
    }
    return '';
  }
  var box = ringBox(), who = box ? nameNear(box) : '';
  var inCall = buttons().some(function (b) { return HANG.test((b.getAttribute('aria-label') || '')); });
  var out = /^\\/(login|register)/.test(location.pathname);
  return JSON.stringify({
    ringing: !!box, who: who.slice(0, 60), inCall: inCall, loggedOut: out, path: location.pathname,
    title: String(document.title || '').slice(0, 200), n: window.__mhNotifN || 0
  });
})();
''';

  /// Appuie sur un bouton : 'answer', 'answerVideo', 'decline', 'hangup',
  /// 'joinVoice'.
  static String buttonScript(String what) =>
      '''
(function (what) {
$_helpers
  function press(list, re) {
    for (var i = 0; i < list.length; i++) {
      if (re.test(lab(list[i]))) { list[i].click(); return true; }
    }
    return false;
  }
  if (what === 'answer' || what === 'answerVideo' || what === 'decline') {
    var box = ringBox();
    if (!box) return false;
    var bs = buttons(box);
    if (what === 'decline') return press(bs, DEC);
    if (what === 'answerVideo') {
      var v = bs.filter(function (x) { return ACC.test(lab(x)) && VID.test(lab(x)); });
      if (v.length) { v[0].click(); return true; }
    }
    var a = bs.filter(function (x) { return ACC.test(lab(x)) && !VID.test(lab(x)); });
    if (a.length) { a[0].click(); return true; }
    return press(bs, ACC);
  }
  if (what === 'hangup') {
    var hs = buttons().filter(function (b) { return HANG.test(b.getAttribute('aria-label') || ''); });
    if (hs.length) { hs[0].click(); return true; }
    return false;
  }
  if (what === 'joinVoice') return press(buttons(), JOIN);
  return false;
})(${jsonEncode(what)});
''';
}

/// Le Discord caché derrière Mon Hub, et ce qu'on voit de lui : la sonnerie
/// (Répondre / Refuser), la fenêtre d'appel, la pastille « appel en cours ».
class DiscordPhoneLayer extends StatelessWidget {
  const DiscordPhoneLayer({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final phone = DiscordPhone.instance;
    return ListenableBuilder(
      listenable: phone,
      builder: (context, _) {
        final shown = phone.active && phone.shown;
        return Stack(
          children: [
            // Toujours à la même place dans l'arbre : le Discord caché n'est
            // jamais rechargé quand on l'affiche ou le cache.
            // (Chaque morceau a sa clé : Mon Hub n'est jamais reconstruit
            // quand le Discord caché apparaît.)
            if (phone.active)
              Positioned.fill(
                key: const ValueKey('phone-web'),
                top: shown ? 52 : 0,
                child: DiscordPhone.testWebView?.call(context) ?? const _PhoneWebView(),
              ),
            // Mon Hub par-dessus (caché quand la fenêtre d'appel est ouverte).
            Positioned.fill(
              key: const ValueKey('hub'),
              child: Offstage(offstage: shown, child: child),
            ),
            if (shown)
              Positioned(
                key: const ValueKey('phone-bar'),
                top: 0,
                left: 0,
                right: 0,
                height: 52,
                child: _CallBar(phone: phone),
              ),
            if (!shown && phone.state == PhoneState.ringing)
              Positioned(
                key: const ValueKey('phone-ring'),
                top: 16,
                right: 16,
                child: _RingCard(phone: phone),
              ),
            if (!shown && (phone.state == PhoneState.inCall || phone.state == PhoneState.calling))
              Positioned(
                key: const ValueKey('phone-pill'),
                bottom: 18,
                left: 0,
                right: 0,
                child: Center(child: _InCallPill(phone: phone)),
              ),
          ],
        );
      },
    );
  }
}

const _discordColor = Color(0xFF5865F2);

class _PhoneWebView extends StatelessWidget {
  const _PhoneWebView();

  @override
  Widget build(BuildContext context) => InAppWebView(
    initialUrlRequest: URLRequest(url: WebUri(DiscordPhone.home)),
    initialSettings: InAppWebViewSettings(
      javaScriptEnabled: true,
      thirdPartyCookiesEnabled: true,
      mediaPlaybackRequiresUserGesture: false,
      allowsInlineMediaPlayback: true,
      domStorageEnabled: true,
      databaseEnabled: true,
    ),
    // Le flou de la caméra : l'image passe par Mon Hub avant de partir.
    initialUserScripts: UnmodifiableListView([
      UserScript(
        source: CamBlur.script(CamBlur.instance.mode),
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
      ),
      // Les notifications que Discord voudrait montrer : relayées à Mon Hub,
      // qui relève tout de suite (au lieu de toutes les 2 minutes).
      UserScript(source: WebNotify.shimScript, injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START),
    ]),
    onWebViewCreated: DiscordPhone.instance.attach,
    // Micro et caméra pour les appels.
    onPermissionRequest: (_, req) async =>
        PermissionResponse(resources: req.resources, action: PermissionResponseAction.GRANT),
  );
}

class _CallBar extends StatelessWidget {
  const _CallBar({required this.phone});
  final DiscordPhone phone;

  @override
  Widget build(BuildContext context) {
    final inCall = phone.state == PhoneState.inCall || phone.state == PhoneState.calling;
    return Material(
      color: _discordColor,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            IconButton(color: Colors.white, icon: const Icon(Icons.arrow_back_rounded), onPressed: phone.hide),
            const SizedBox(width: 4),
            const Icon(Icons.forum_rounded, color: Colors.white, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                inCall ? 'Appel Discord${phone.who.isEmpty ? '' : ' · ${phone.who}'}' : 'Discord',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
              ),
            ),
            const _BlurButton(),
            const SizedBox(width: 6),
            if (inCall)
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: const Color(0xFFED4245)),
                icon: const Icon(Icons.call_end_rounded, size: 18),
                label: const Text('Raccrocher'),
                onPressed: phone.hangUp,
              ),
            const SizedBox(width: 6),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              onPressed: phone.hide,
              child: const Text('Réduire'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Le flou de la caméra, à changer quand on veut (même en plein appel).
class _BlurButton extends StatelessWidget {
  const _BlurButton();

  @override
  Widget build(BuildContext context) {
    final blur = CamBlur.instance;
    return ListenableBuilder(
      listenable: blur,
      builder: (context, _) => PopupMenuButton<String>(
        tooltip: 'Flou de la caméra',
        initialValue: blur.mode,
        onSelected: (m) => unawaited(blur.setMode(m)),
        itemBuilder: (_) => [for (final m in CamBlur.modes) PopupMenuItem(value: m, child: Text(CamBlur.label(m)))],
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(blur.mode == 'non' ? Icons.blur_off_rounded : Icons.blur_on_rounded, color: Colors.white, size: 20),
              const SizedBox(width: 6),
              Text(CamBlur.label(blur.mode), style: const TextStyle(color: Colors.white)),
            ],
          ),
        ),
      ),
    );
  }
}

class _RingCard extends StatelessWidget {
  const _RingCard({required this.phone});
  final DiscordPhone phone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      elevation: 12,
      borderRadius: BorderRadius.circular(24),
      color: theme.colorScheme.surface,
      child: Container(
        width: 320,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          gradient: LinearGradient(
            colors: [_discordColor.withValues(alpha: 0.22), _discordColor.withValues(alpha: 0.05)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const _Pulse(),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Appel Discord', style: theme.textTheme.labelMedium),
                      Text(
                        phone.who.isEmpty ? 'On t\'appelle' : phone.who,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: const Color(0xFFED4245)),
                    icon: const Icon(Icons.call_end_rounded, size: 18),
                    label: const Text('Refuser'),
                    onPressed: phone.decline,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: const Color(0xFF23A55A)),
                    icon: const Icon(Icons.call_rounded, size: 18),
                    label: const Text('Répondre'),
                    onPressed: phone.answer,
                  ),
                ),
              ],
            ),
            TextButton.icon(
              icon: const Icon(Icons.videocam_rounded, size: 18),
              label: const Text('Répondre en vidéo'),
              onPressed: () => phone.answer(video: true),
            ),
          ],
        ),
      ),
    );
  }
}

/// L'icône d'appel qui « sonne » (s'agrandit et rétrécit).
class _Pulse extends StatefulWidget {
  const _Pulse();

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final _a = AnimationController(vsync: this, duration: const Duration(milliseconds: 700))..repeat(reverse: true);

  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ScaleTransition(
    scale: Tween(begin: 0.9, end: 1.1).animate(CurvedAnimation(parent: _a, curve: Curves.easeInOut)),
    child: Container(
      width: 46,
      height: 46,
      decoration: const BoxDecoration(color: _discordColor, shape: BoxShape.circle),
      child: const Icon(Icons.ring_volume_rounded, color: Colors.white),
    ),
  );
}

class _InCallPill extends StatelessWidget {
  const _InCallPill({required this.phone});
  final DiscordPhone phone;

  @override
  Widget build(BuildContext context) => Material(
    elevation: 8,
    color: _discordColor,
    borderRadius: BorderRadius.circular(30),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.graphic_eq_rounded, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Text(
            phone.state == PhoneState.calling
                ? 'Appel en cours de lancement…'
                : 'En appel${phone.who.isEmpty ? '' : ' avec ${phone.who}'}',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
          ),
          const SizedBox(width: 8),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            onPressed: phone.show,
            child: const Text('Afficher'),
          ),
          IconButton(
            style: IconButton.styleFrom(backgroundColor: const Color(0xFFED4245)),
            color: Colors.white,
            icon: const Icon(Icons.call_end_rounded, size: 18),
            onPressed: phone.hangUp,
          ),
        ],
      ),
    ),
  );
}
