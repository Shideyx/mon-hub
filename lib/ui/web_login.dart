import 'dart:async';
import 'dart:collection';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_ui/material_ui.dart';

import '../core/browser.dart';
import '../core/scam_shield.dart';
import '../core/freeze_watch.dart';

const _desktopUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/142.0.0.0 Safari/537.36';

/// Identité « Chrome de bureau » avec la **vraie** version du moteur (Edge
/// WebView2 = Chromium) : une version figée vieillit, et Google Docs finit
/// par croire que le navigateur est trop ancien (fonctions coupées, bandeau).
String desktopUserAgent([String? engineVersion]) {
  final major = RegExp(r'^(\d{2,4})\.').firstMatch(engineVersion ?? '')?.group(1);
  if (major == null) return _desktopUa;
  return 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/$major.0.0.0 Safari/537.36';
}

String? _engineUa;
Future<String>? _engineUaLoading;

/// La version du moteur, demandée une seule fois.
Future<String> _loadEngineUa() => _engineUaLoading ??= () async {
  String? v;
  try {
    if (!kIsWeb && Platform.isWindows) v = await WebViewEnvironment.getAvailableVersion();
  } catch (_) {}
  return _engineUa = desktopUserAgent(v);
}();

/// Le navigateur intégré existe sur Windows, Android, iPhone et Mac.
/// Sur Linux, on retombe sur la saisie manuelle.
bool get webLoginSupported =>
    !kIsWeb && (Platform.isWindows || Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

/// Page de connexion intégrée : tu te connectes sur le vrai site
/// (instagram.com, discord.com…) et l'appli récupère toute seule l'accès
/// dont elle a besoin. Ton mot de passe n'est jamais lu par Mon Hub.
class WebLoginPage extends StatefulWidget {
  const WebLoginPage({
    super.key,
    required this.title,
    required this.url,
    this.cookieName,
    this.cookieUrl,
    this.captureAuthorizationHeader = false,
    this.returnAllCookies = false,
    this.validate,
  });

  /// Vérifie un jeton capturé avant de fermer la page (sinon on continue
  /// d'attendre le bon).
  final Future<bool> Function(String value)? validate;

  /// Une fois [cookieName] présent, renvoie tous les cookies du site sous
  /// forme d'en-tête `Cookie` (nécessaire pour envoyer des messages).
  final bool returnAllCookies;

  final String title;
  final String url;

  /// Cookie à récupérer après connexion (ex. `sessionid` pour Instagram).
  final String? cookieName;
  final String? cookieUrl;

  /// Récupère l'en-tête `Authorization` des requêtes du site (Discord).
  final bool captureAuthorizationHeader;

  /// Ouvre la page et renvoie le jeton / cookie obtenu, ou null.
  static Future<String?> open(BuildContext context, WebLoginPage page) =>
      Navigator.push<String>(context, MaterialPageRoute(builder: (_) => page));

  @override
  State<WebLoginPage> createState() => _WebLoginPageState();
}

class _WebLoginPageState extends State<WebLoginPage> {
  InAppWebViewController? _c;
  Timer? _timer;
  bool _done = false;
  double _progress = 0;
  final _tried = <String>{};

  static const _hookScript = r'''
(function () {
  if (window.__hubHooked) return; window.__hubHooked = true;
  var sent = null;
  function send(v) {
    if (!v || v === sent || v.indexOf('Bot ') === 0) return;
    sent = v;
    try { window.flutter_inappwebview.callHandler('hubToken', v); } catch (e) {}
  }
  var o = XMLHttpRequest.prototype.setRequestHeader;
  XMLHttpRequest.prototype.setRequestHeader = function (k, v) {
    if (String(k).toLowerCase() === 'authorization') send(v);
    return o.apply(this, arguments);
  };
  var f = window.fetch;
  window.fetch = function (i, init) {
    try {
      var h = init && init.headers, v = null;
      if (h) v = (typeof h.get === 'function') ? h.get('authorization') : (h.Authorization || h.authorization);
      if (v) send(v);
    } catch (e) {}
    return f.apply(this, arguments);
  };
})();
''';

  void _finish(String value) {
    if (_done || !mounted) return;
    _done = true;
    _timer?.cancel();
    Navigator.pop(context, value);
  }

  /// Renvoie true si la session a été trouvée.
  Future<bool> _checkCookie() async {
    final name = widget.cookieName;
    if (name == null || _done) return _done;
    try {
      final url = WebUri(widget.cookieUrl ?? widget.url);
      final all = await CookieManager.instance().getCookies(url: url, webViewController: _c);
      String clean(Object? v) => '${v ?? ''}'.replaceAll('"', '').trim();
      final hit = all.where((c) => c.name == name && clean(c.value).isNotEmpty).firstOrNull;
      if (hit == null) return false;
      _finish(
        widget.returnAllCookies
            ? all.where((c) => clean(c.value).isNotEmpty).map((c) => '${c.name}=${clean(c.value)}').join('; ')
            : clean(hit.value),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _manualCheck() async {
    if (await _checkCookie() || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Connexion pas encore détectée. Termine la connexion sur la page '
          '(code de sécurité, « Enregistrer les identifiants »…) puis réessaie.',
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    if (widget.cookieName != null) {
      _timer = Timer.periodic(const Duration(seconds: 2), (_) => _checkCookie());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          if (widget.cookieName != null)
            TextButton.icon(
              onPressed: _manualCheck,
              icon: const Icon(Icons.check_rounded),
              label: const Text("J'ai fini"),
            ),
        ],
        bottom: _progress < 1
            ? PreferredSize(
                preferredSize: const Size.fromHeight(3),
                child: LinearProgressIndicator(value: _progress, minHeight: 3),
              )
            : null,
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: Theme.of(context).colorScheme.secondaryContainer,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: const Text(
              '🔒 Connecte-toi normalement. Dès que c\'est fait, la page se ferme toute '
              'seule. Mon Hub ne voit pas ton mot de passe, seulement la session.',
            ),
          ),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(widget.url)),
              initialSettings: InAppWebViewSettings(
                userAgent: _desktopUa,
                javaScriptEnabled: true,
                thirdPartyCookiesEnabled: true,
              ),
              initialUserScripts: widget.captureAuthorizationHeader
                  ? UnmodifiableListView([
                      UserScript(source: _hookScript, injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START),
                    ])
                  : null,
              onWebViewCreated: (c) {
                _c = c;
                c.addJavaScriptHandler(
                  handlerName: 'hubToken',
                  callback: (args) async {
                    final v = args.isEmpty ? '' : '${args.first}';
                    if (v.length <= 20 || _tried.contains(v)) return null;
                    _tried.add(v);
                    final check = widget.validate;
                    if (check == null || await check(v)) _finish(v);
                    return null;
                  },
                );
              },
              onProgressChanged: (_, p) => setState(() => _progress = p / 100),
              onUpdateVisitedHistory: (_, _, _) => _checkCookie(),
              onLoadStop: (c, _) async {
                if (widget.captureAuthorizationHeader) {
                  // Ceinture et bretelles si le script n'a pas été injecté tôt.
                  await c.evaluateJavascript(source: _hookScript);
                }
                await _checkCookie();
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Site web intégré dans l'appli (session gardée d'une fois sur l'autre).
class HubWebView extends StatefulWidget {
  const HubWebView({
    super.key,
    required this.url,
    this.desktopUserAgent = false,
    this.onController,
    this.onTitleChanged,
    this.reloadButton = true,
    this.sameSiteInPlace = false,
    this.userScripts,
  });
  final String url;
  final bool desktopUserAgent;

  /// Scripts mis **avant** le site, dans la page et ses fenêtres (appels
  /// Instagram : le flou de la caméra). Relus à chaque fenêtre ouverte.
  final List<UserScript> Function()? userScripts;

  /// Le petit bouton « Recharger » flottant en haut à droite. À couper quand
  /// la page a ses propres boutons à cet endroit (Google Docs : « Partager »)
  /// et que l'écran a déjà « Recharger » dans sa barre.
  final bool reloadButton;

  /// Un lien du même site qui veut s'ouvrir dans un nouvel onglet s'ouvre
  /// ici (Google Docs : « Nouveau document », « Ouvrir dans un nouvel
  /// onglet ») au lieu d'une fenêtre sans boutons.
  final bool sameSiteInPlace;

  /// Le titre de la page a changé (ex. « (2) Instagram » : 2 non lus).
  final void Function(String? title)? onTitleChanged;

  /// Donne le contrôleur de la page (pour y lancer du JavaScript).
  final void Function(InAppWebViewController c)? onController;

  @override
  State<HubWebView> createState() => _HubWebViewState();
}

class _HubWebViewState extends State<HubWebView> {
  InAppWebViewController? _c;

  /// La barre de chargement : seule elle se redessine pendant le chargement
  /// (avant : toute la page, navigateur compris, à chaque pourcent).
  final _progress = ValueNotifier<double>(0);
  bool _blank = false;
  Timer? _blankCheck;
  bool get _wantsUa => widget.desktopUserAgent && !(Platform.isAndroid || Platform.isIOS);

  /// Les réglages ne changent pas : créés une fois.
  late InAppWebViewSettings _settings = _makeSettings();

  InAppWebViewSettings _makeSettings() => InAppWebViewSettings(
    userAgent: _wantsUa ? (_engineUa ?? _desktopUa) : null,
    javaScriptEnabled: true,
    thirdPartyCookiesEnabled: true,
    supportMultipleWindows: true,
    javaScriptCanOpenWindowsAutomatically: true,
    mediaPlaybackRequiresUserGesture: false,
    allowsInlineMediaPlayback: true,
    domStorageEnabled: true,
    databaseEnabled: true,
  );

  @override
  void initState() {
    super.initState();
    FreezeWatch.note('ouvre la page ${Uri.tryParse(widget.url)?.host ?? ''}');
    if (_wantsUa && _engineUa == null) {
      // La première fois, on attend la version du moteur (quelques ms).
      unawaited(
        _loadEngineUa().then((_) {
          if (mounted) setState(() => _settings = _makeSettings());
        }),
      );
    }
  }

  /// Après chargement, vérifie que la page n'est pas restée blanche (site qui
  /// attend une fenêtre de connexion, script bloqué…). Vérification légère :
  /// `textContent` ne fait pas recalculer la mise en page (avant :
  /// `innerText` sur tout un Google Doc, très lourd).
  void _scheduleBlankCheck() {
    _blankCheck?.cancel();
    _blankCheck = Timer(const Duration(seconds: 6), () async {
      final c = _c;
      if (c == null || !mounted) return;
      try {
        final n = await c.evaluateJavascript(
          source:
              "(function(){var b=document.body;if(!b)return 0;"
              "if(b.querySelector('img,svg,canvas,video,input,button,iframe,[contenteditable]'))return 1;"
              "return (b.textContent||'').trim().length>0?1:0;})()",
        );
        final blank = (n is num ? n : num.tryParse('$n') ?? 1) == 0;
        if (mounted && blank != _blank) setState(() => _blank = blank);
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _blankCheck?.cancel();
    _c = null;
    _progress.dispose();
    super.dispose();
  }

  static bool _isLogin(Uri? u) {
    if (u == null) return true;
    final h = u.host.toLowerCase();
    final p = u.path.toLowerCase();
    return u.toString() == 'about:blank' ||
        h.isEmpty ||
        h.startsWith('accounts.') ||
        h.contains('login') ||
        h.contains('auth') ||
        p.contains('oauth') ||
        p.contains('login') ||
        p.contains('signin') ||
        p.contains('/auth');
  }

  /// Deux adresses du même site (docs.google.com / drive.google.com non).
  static bool _sameSite(Uri? a, Uri? b) => a != null && b != null && a.host.isNotEmpty && a.host == b.host;

  Future<void> _reload() async {
    setState(() => _blank = false);
    final c = _c;
    if (c == null) return;
    final url = await c.getUrl();
    // Une page blanche après connexion se règle souvent en rouvrant l'adresse de départ.
    await c.loadUrl(urlRequest: URLRequest(url: _blank || url == null ? WebUri(widget.url) : url));
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final c = _c;
        if (c != null && await c.canGoBack()) {
          await c.goBack();
        } else if (context.mounted) {
          Navigator.of(context).maybePop();
        }
      },
      child: Stack(
        children: [
          if (_wantsUa && _engineUa == null)
            const SizedBox.expand()
          else
            InAppWebView(
              key: const ValueKey('hub-webview'),
              initialUrlRequest: URLRequest(url: WebUri(widget.url)),
              initialSettings: _settings,
              initialUserScripts: widget.userScripts == null ? null : UnmodifiableListView(widget.userScripts!()),
              onWebViewCreated: (c) {
                _c = c;
                widget.onController?.call(c);
              },
              onProgressChanged: (_, p) => _progress.value = p / 100,
              onLoadStop: (_, _) => _scheduleBlankCheck(),
              onTitleChanged: widget.onTitleChanged == null ? null : (_, t) => widget.onTitleChanged!(t),
              onUpdateVisitedHistory: (_, _, _) => _scheduleBlankCheck(),
              // Fenêtres « pop-up » (connexion Google, Apple…) : on les ouvre
              // dans une vraie fenêtre liée à la page, pour que le site reçoive
              // la réponse (sinon la page restait blanche après connexion).
              onCreateWindow: (c, action) async {
                if (!mounted) return false;
                final to = action.request.url;
                // Bouclier anti-arnaque : un faux site ne s'ouvre pas tout seul.
                if (to != null) {
                  final v = ScamShield.checkUrl(to.toString());
                  if (v.danger && !(await Browser.confirmScam?.call(to.toString(), v) ?? false)) return true;
                }
                if (widget.sameSiteInPlace && !_isLogin(to) && _sameSite(to, await c.getUrl())) {
                  // false : le lien s'ouvre ici même.
                  return false;
                }
                if (!context.mounted) return false;
                unawaited(
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      fullscreenDialog: true,
                      builder: (_) => _PopupWindow(
                        action: action,
                        settings: _settings,
                        login: _isLogin(to),
                        scripts: widget.userScripts,
                      ),
                    ),
                  ).then((_) => _scheduleBlankCheck()),
                );
                return true;
              },
              onPermissionRequest: (_, req) async =>
                  PermissionResponse(resources: req.resources, action: PermissionResponseAction.GRANT),
            ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: ValueListenableBuilder<double>(
              valueListenable: _progress,
              builder: (context, p, _) =>
                  p < 1 ? LinearProgressIndicator(value: p, minHeight: 3) : const SizedBox.shrink(),
            ),
          ),
          if (widget.reloadButton)
            Positioned(
              right: 12,
              top: 12,
              child: Material(
                color: Theme.of(context).colorScheme.surfaceContainerHigh.withValues(alpha: 0.9),
                shape: const CircleBorder(),
                child: IconButton(
                  tooltip: 'Recharger',
                  icon: const Icon(Icons.refresh_rounded, size: 20),
                  onPressed: _reload,
                ),
              ),
            ),
          if (_blank)
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const Text('La page reste blanche ?'),
                      FilledButton.tonal(onPressed: _reload, child: const Text('Recharger')),
                      TextButton(
                        onPressed: () => Browser.open(widget.url),
                        child: const Text('Ouvrir dans le navigateur'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Fenêtre ouverte par un site (connexion Google, ou un lien), reliée à la
/// page d'origine.
class _PopupWindow extends StatefulWidget {
  const _PopupWindow({required this.action, required this.settings, required this.login, this.scripts});
  final CreateWindowAction action;
  final InAppWebViewSettings settings;
  final List<UserScript> Function()? scripts;
  final bool login;

  @override
  State<_PopupWindow> createState() => _PopupWindowState();
}

class _PopupWindowState extends State<_PopupWindow> {
  late String _title = widget.login ? 'Connexion' : (widget.action.request.url?.host ?? 'Lien');
  InAppWebViewController? _c;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (!widget.login)
            IconButton(
              tooltip: 'Ouvrir dans le navigateur',
              icon: const Icon(Icons.open_in_new_rounded),
              onPressed: () async {
                final u = await _c?.getUrl() ?? widget.action.request.url;
                if (u != null) await Browser.open(u.toString());
              },
            ),
        ],
      ),
      body: InAppWebView(
        windowId: widget.action.windowId,
        initialSettings: widget.settings,
        initialUserScripts: widget.scripts == null ? null : UnmodifiableListView(widget.scripts!()),
        // La fenêtre d'appel (Instagram…) : caméra et micro autorisés (avant :
        // rien n'était répondu, l'appel n'avait ni image ni son).
        onPermissionRequest: (_, req) async =>
            PermissionResponse(resources: req.resources, action: PermissionResponseAction.GRANT),
        onWebViewCreated: (c) => _c = c,
        onTitleChanged: widget.login
            ? null
            : (_, t) {
                if (mounted && t != null && t.trim().isNotEmpty) setState(() => _title = t.trim());
              },
        onCloseWindow: (_) {
          if (context.mounted) Navigator.maybePop(context);
        },
      ),
    );
  }
}
