import 'dart:convert';

/// Les notifications des **vrais sites** (discord.com, instagram.com) ouverts
/// en fond dans Mon Hub, comme un onglet de navigateur.
///
/// Rien n'est demandé au site : on regarde seulement ce que la page affiche
/// elle-même — le nombre de non-lus dans son titre (« (3) Instagram ») — et
/// les notifications qu'elle voudrait montrer (l'API `Notification` du
/// navigateur, remplacée par un petit relais qui les passe à Mon Hub).
class WebNotify {
  WebNotify._();

  /// Mis **avant** le site : `new Notification(...)` est gardé pour Mon Hub
  /// (titre, texte) au lieu d'être perdu, et la permission est accordée.
  static const shimScript = r'''
(function () {
  if (window.__mhNotifShim) return;
  window.__mhNotifShim = true;
  window.__mhNotifN = 0;
  window.__mhNotifLast = null;
  function Relay(title, opts) {
    opts = opts || {};
    try {
      window.__mhNotifN++;
      window.__mhNotifLast = {
        t: String(title || '').slice(0, 120),
        b: String(opts.body || '').slice(0, 400)
      };
    } catch (e) {}
    this.title = title;
    this.body = opts.body || '';
    this.tag = opts.tag || '';
    this.data = opts.data;
    this.onclick = null;
    this.onclose = null;
    this.onshow = null;
    this.onerror = null;
  }
  Relay.prototype.close = function () {};
  Relay.prototype.addEventListener = function () {};
  Relay.prototype.removeEventListener = function () {};
  Relay.prototype.dispatchEvent = function () { return true; };
  Relay.permission = 'granted';
  Relay.maxActions = 0;
  Relay.requestPermission = function (cb) {
    try { if (cb) cb('granted'); } catch (e) {}
    return Promise.resolve('granted');
  };
  try {
    Object.defineProperty(window, 'Notification', { value: Relay, writable: true, configurable: true });
  } catch (e) {
    window.Notification = Relay;
  }
})();
''';

  /// Ce que la page montre maintenant (en JSON) : titre, nombre de
  /// notifications relayées, la dernière, page de connexion ?
  static String statusScript({required String loginPattern}) =>
      '''
(function () {
  return JSON.stringify({
    title: String(document.title || '').slice(0, 200),
    n: window.__mhNotifN || 0,
    last: window.__mhNotifLast || null,
    loggedOut: new RegExp(${jsonEncode(loginPattern)}).test(location.pathname)
  });
})();
''';

  /// Le nombre entre parenthèses au début du titre (« (3) Instagram » → 3),
  /// null s'il n'y en a pas.
  static int? countInTitle(String? title) {
    final m = RegExp(r'^\s*\((\d+)\)').firstMatch(title ?? '');
    return m == null ? null : int.tryParse(m[1]!);
  }

  /// Ce que la page vient d'annoncer, comparé à avant. Sans navigateur :
  /// testable.
  ///
  /// * plus de non-lus dans le titre qu'avant → du nouveau ;
  /// * une notification de plus relayée → du nouveau (avec son texte).
  static WebNews? news({
    required int? before,
    required int? now,
    required int notifsBefore,
    required int notifsNow,
    Map<String, dynamic>? last,
  }) {
    final more = (now ?? 0) > (before ?? 0);
    final relayed = notifsNow > notifsBefore;
    if (!more && !relayed) return null;
    final title = relayed ? '${last?['t'] ?? ''}'.trim() : '';
    final body = relayed ? '${last?['b'] ?? ''}'.trim() : '';
    return WebNews(count: now ?? 0, title: title, body: body);
  }
}

/// Du nouveau sur un site ouvert en fond.
class WebNews {
  const WebNews({required this.count, this.title = '', this.body = ''});

  /// Non-lus annoncés par le titre de la page (0 si inconnu).
  final int count;

  /// Ce que la notification du site disait (vide si aucune).
  final String title;
  final String body;
}
