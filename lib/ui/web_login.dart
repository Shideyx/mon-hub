import 'dart:async';
import 'dart:collection';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_ui/material_ui.dart';

const _desktopUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/131.0.0.0 Safari/537.36';

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
  });

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
            ? all
                  .where((c) => clean(c.value).isNotEmpty)
                  .map((c) => '${c.name}=${clean(c.value)}')
                  .join('; ')
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
                      UserScript(
                        source: _hookScript,
                        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                      ),
                    ])
                  : null,
              onWebViewCreated: (c) {
                _c = c;
                c.addJavaScriptHandler(
                  handlerName: 'hubToken',
                  callback: (args) {
                    final v = args.isEmpty ? '' : '${args.first}';
                    if (v.length > 20) _finish(v);
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
