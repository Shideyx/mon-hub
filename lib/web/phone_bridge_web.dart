import 'dart:js_interop';

@JS('smily.standalone')
external JSBoolean _standalone();
@JS('smily.ios')
external JSBoolean _ios();
@JS('smily.notifyState')
external JSString _notifyState();
@JS('smily.askNotify')
external JSPromise<JSString> _askNotify();
@JS('smily.notify')
external JSPromise<JSBoolean> _notify(JSString title, JSString body, JSString tag);
@JS('smily.share')
external JSPromise<JSBoolean> _share(JSString text);
@JS('smily.vibrate')
external JSBoolean _vibrate(JSNumber ms);
@JS('smily.openFile')
external void _openFile(JSString name, JSString mime, JSString text);
@JS('smily.hash')
external JSString _hash();
@JS('smily.clearHash')
external void _clearHash();
@JS('smily.hidden')
external JSBoolean _hidden();

/// Le pont vers `web/smily.js` (fonctions du navigateur du téléphone).
class PhoneBridge {
  PhoneBridge._();

  static T _safe<T>(T Function() f, T or) {
    try {
      return f();
    } catch (_) {
      return or;
    }
  }

  /// Ouvert depuis l'écran d'accueil (comme une appli) ?
  static bool get standalone => _safe(() => _standalone().toDart, false);
  static bool get ios => _safe(() => _ios().toDart, false);

  /// granted / denied / default / absent.
  static String get notifyState => _safe(() => _notifyState().toDart, 'absent');

  static Future<String> askNotify() async {
    try {
      return (await _askNotify().toDart).toDart;
    } catch (_) {
      return 'absent';
    }
  }

  static Future<bool> notify(String title, String body, {String tag = ''}) async {
    try {
      return (await _notify(title.toJS, body.toJS, tag.toJS).toDart).toDart;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> share(String text) async {
    try {
      return (await _share(text.toJS).toDart).toDart;
    } catch (_) {
      return false;
    }
  }

  static bool vibrate(int ms) => _safe(() => _vibrate(ms.toJS).toDart, false);

  static void openFile(String name, String mime, String text) =>
      _safe(() => _openFile(name.toJS, mime.toJS, text.toJS), null);

  static String get hash => _safe(() => _hash().toDart, '');
  static void clearHash() => _safe(() => _clearHash(), null);

  /// L'appli est en arrière-plan (onglet caché) ?
  static bool get hidden => _safe(() => _hidden().toDart, false);
}
