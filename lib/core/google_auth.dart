import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'module_store.dart';
import 'browser.dart';

/// « Se connecter avec Google » (OAuth officiel) pour Gmail et Google Agenda.
///
/// L'ID client est fourni au moment de la compilation (secrets GitHub
/// GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET → --dart-define). Pour une appli
/// installée, Google considère que ce « secret » n'en est pas vraiment un.
///
/// Flux « adresse de bouclage » : l'appli ouvre la page Google dans le
/// navigateur, la personne accepte, Google renvoie vers
/// `http://127.0.0.1:port` où l'appli récupère le code.
class GoogleAuth {
  GoogleAuth._();

  /// Identifiants « application de bureau » de Google : fournis à la
  /// construction (secrets GitHub GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET),
  /// sinon collés dans Réglages → Compte Google (ils ne sont pas secrets
  /// pour une appli installée, Google le dit lui-même).
  static const builtInId = String.fromEnvironment('GOOGLE_CLIENT_ID');
  static const _builtInSecret = String.fromEnvironment('GOOGLE_CLIENT_SECRET');

  static String get clientId => builtInId.isNotEmpty ? builtInId : _custom().$1;
  static String get clientSecret => builtInId.isNotEmpty ? _builtInSecret : _custom().$2;
  static bool get available => clientId.isNotEmpty;

  static const _customKey = 'google.client';

  static (String, String) _custom() {
    try {
      final raw = ModuleStore.prefs.getString(_customKey);
      if (raw == null) return ('', '');
      final j = jsonDecode(raw) as Map;
      return ('${j['id'] ?? ''}'.trim(), '${j['secret'] ?? ''}'.trim());
    } catch (_) {
      return ('', '');
    }
  }

  /// Enregistre les identifiants collés par la personne.
  static Future<void> setClient(String id, String secret) async {
    final i = id.trim();
    if (i.isEmpty) {
      await ModuleStore.prefs.remove(_customKey);
      return;
    }
    if (!i.endsWith('.apps.googleusercontent.com')) {
      throw 'Ce n\'est pas un identifiant client Google (il finit par « .apps.googleusercontent.com »)';
    }
    await ModuleStore.prefs.setString(_customKey, jsonEncode({'id': i, 'secret': secret.trim()}));
  }

  /// Le « code de liaison » à donner à un autre appareil (l'iPhone) : la
  /// clé de l'appli Google de la personne, pour qu'il se connecte sans
  /// refaire les 5 étapes. Passe par toi (copier-coller, ton propre mail) :
  /// jamais par un serveur.
  static const codePrefix = 'MONHUB-GOOGLE:';

  static String? shareCode() {
    if (!available) return null;
    final raw = utf8.encode(jsonEncode({'id': clientId, 'secret': clientSecret}));
    return '$codePrefix${base64Url.encode(raw).replaceAll('=', '')}';
  }

  /// Lit un code de liaison (dans un texte collé, un mail…). Renvoie false
  /// s'il n'y en a pas.
  static Future<bool> importCode(String text) async {
    final m = RegExp('${RegExp.escape(codePrefix)}\\s*([A-Za-z0-9_-]{20,})').firstMatch(text);
    if (m == null) return false;
    final Object? j;
    try {
      j = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(m[1]!))));
    } catch (_) {
      throw 'Ce code est abîmé : recopie-le en entier depuis ton PC.';
    }
    if (j is! Map) throw 'Ce code est abîmé : recopie-le en entier depuis ton PC.';
    await setClient('${j['id'] ?? ''}', '${j['secret'] ?? ''}');
    return true;
  }

  /// Sur iPhone (et Android) : la page Google s'ouvre **dans** Mon Hub
  /// (Safari intégré), pour que l'appli reste ouverte et reçoive la réponse.
  static bool get _mobile => !Platform.isWindows && !Platform.isMacOS && !Platform.isLinux;

  static Future<bool> _openSignIn(Uri url) async {
    if (!_mobile) return Browser.open(url.toString());
    try {
      return await launchUrl(url, mode: LaunchMode.inAppBrowserView);
    } catch (_) {
      return Browser.open(url.toString());
    }
  }

  static Future<void> _closeSignIn() async {
    if (!_mobile) return;
    try {
      await closeInAppWebView();
    } catch (_) {}
  }

  static const scopes = [
    'openid',
    'email',
    'https://mail.google.com/',
    'https://www.googleapis.com/auth/calendar',
    // Ton Drive en entier : le lire, y ranger tes fichiers (Smily), ouvrir
    // et enregistrer tes Google Docs dans le Word de Mon Hub.
    driveScope,
  ];

  static const driveScope = 'https://www.googleapis.com/auth/drive';

  /// Le compte Google utilisé pour le Drive et les Docs (celui choisi dans
  /// le module Drive, sinon le premier).
  static String? get driveAccount {
    final saved = (ModuleStore()..bind('drive')).getJson<String>('account');
    final all = accounts;
    if (saved != null && all.contains(saved)) return saved;
    return all.firstOrNull;
  }

  /// Le compte a donné l'accès complet au Drive (les comptes connectés avant
  /// la v1.37 n'avaient que la lecture : il faut les reconnecter).
  static bool canWriteDrive(String email) =>
      (store.getJson<String>('scopes.$email') ?? '').split(' ').contains(driveScope);

  static final ModuleStore store = ModuleStore()..bind('google');

  /// Comptes Google connectés (adresses).
  static List<String> get accounts => (store.getJson<List<dynamic>>('accounts') ?? const []).cast<String>();

  static final _tokens = <String, (String, DateTime)>{};

  static String _rand(int n) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final r = Random.secure();
    return List.generate(n, (_) => chars[r.nextInt(chars.length)]).join();
  }

  /// Ouvre la page Google et renvoie l'adresse du compte connecté.
  static Future<String> signIn() async {
    if (!available) throw 'La connexion Google n\'est pas encore activée : Réglages → Connexion Google';
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirect = 'http://127.0.0.1:${server.port}';
    final verifier = _rand(64);
    final challenge = base64Url.encode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', '');
    final state = _rand(24);
    final url = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
      'client_id': clientId,
      'redirect_uri': redirect,
      'response_type': 'code',
      'scope': scopes.join(' '),
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
      'state': state,
      'access_type': 'offline',
      'include_granted_scopes': 'true',
      'prompt': 'consent select_account',
    });
    try {
      if (!await _openSignIn(url)) {
        throw 'Impossible d\'ouvrir le navigateur';
      }
      final code = await () async {
        await for (final req in server) {
          final q = req.uri.queryParameters;
          // Une réponse sans le bon « state » ne vient pas de Google pour
          // cette connexion : ignorée (elle ne peut ni connecter un autre
          // compte, ni annuler la connexion en cours).
          if (q['state'] != state) {
            req.response.statusCode = 404;
            await req.response.close();
            continue;
          }
          final ok = q['code'] != null && q['state'] == state;
          req.response.headers.contentType = ContentType.html;
          req.response.write(
            '<!doctype html><meta charset="utf-8"><title>Mon Hub</title>'
            '<body style="font-family:system-ui;text-align:center;padding:60px">'
            '<h2>${ok ? '✅ C\'est bon !' : '❌ Connexion annulée'}</h2>'
            '<p>Tu peux fermer cette page et revenir dans Mon Hub.</p></body>',
          );
          await req.response.close();
          if (!ok) {
            throw q['error'] == 'access_denied' ? 'Connexion refusée' : 'Connexion annulée';
          }
          return q['code']!;
        }
        throw 'Connexion annulée';
      }().timeout(const Duration(minutes: 5), onTimeout: () => throw 'Temps dépassé : recommence la connexion Google');

      final r = await http.post(
        Uri.parse('https://oauth2.googleapis.com/token'),
        body: {
          'code': code,
          'client_id': clientId,
          'client_secret': clientSecret,
          'redirect_uri': redirect,
          'grant_type': 'authorization_code',
          'code_verifier': verifier,
        },
      );
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.statusCode != 200) throw 'Google a refusé : ${j['error_description'] ?? j['error']}';
      final access = j['access_token'] as String;
      final info = await http.get(
        Uri.parse('https://openidconnect.googleapis.com/v1/userinfo'),
        headers: {'Authorization': 'Bearer $access'},
      );
      final email = (jsonDecode(info.body) as Map<String, dynamic>)['email'] as String;
      final refresh = j['refresh_token'] as String?;
      if (refresh != null) await store.writeSecret('refresh.$email', refresh);
      if (j['scope'] is String) await store.setJson('scopes.$email', j['scope']);
      _tokens[email] = (access, DateTime.now().add(Duration(seconds: (j['expires_in'] as int) - 60)));
      await store.setJson('accounts', {...accounts, email}.toList());
      return email;
    } finally {
      await server.close(force: true);
      unawaited(_closeSignIn());
    }
  }

  static Future<void> signOut(String email) async {
    _tokens.remove(email);
    await store.writeSecret('refresh.$email', null);
    await store.setJson('accounts', accounts.where((a) => a != email).toList());
  }

  /// Jeton d'accès valide (renouvelé automatiquement).
  static Future<String> accessToken(String email) async {
    final t = _tokens[email];
    if (t != null && t.$2.isAfter(DateTime.now())) return t.$1;
    final refresh = await store.readSecret('refresh.$email');
    if (refresh == null) throw 'Reconnecte ton compte Google ($email)';
    final r = await http.post(
      Uri.parse('https://oauth2.googleapis.com/token'),
      body: {
        'client_id': clientId,
        'client_secret': clientSecret,
        'refresh_token': refresh,
        'grant_type': 'refresh_token',
      },
    );
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    if (r.statusCode != 200) {
      throw j['error'] == 'invalid_grant'
          ? 'Connexion Google expirée : reconnecte $email'
          : 'Google : ${j['error_description'] ?? j['error']}';
    }
    final access = j['access_token'] as String;
    _tokens[email] = (access, DateTime.now().add(Duration(seconds: (j['expires_in'] as int) - 60)));
    if (j['scope'] is String) await store.setJson('scopes.$email', j['scope']);
    return access;
  }

  /// Télécharge un fichier (octets) au nom de [email].
  static Future<Uint8List> bytes(String email, String url) async {
    final token = await accessToken(email);
    final res = await http.get(Uri.parse(url), headers: {'Authorization': 'Bearer $token'});
    if (res.statusCode >= 400) throw _error(res);
    return res.bodyBytes;
  }

  /// Envoie un fichier sur le Drive (nouveau, ou nouvelle version de [id]).
  /// [convertTo] : le transformer en Google Doc, Sheet…
  static Future<Map<String, dynamic>> upload(
    String email, {
    required String name,
    required Uint8List data,
    required String mime,
    String? id,
    String? convertTo,
    String? parent,
  }) async {
    final token = await accessToken(email);
    const fields = 'id,name,webViewLink,mimeType';
    http.Response res;
    if (id != null) {
      res = await http.patch(
        Uri.parse('https://www.googleapis.com/upload/drive/v3/files/$id?uploadType=media&fields=$fields'),
        headers: {'Authorization': 'Bearer $token', 'Content-Type': mime},
        body: data,
      );
    } else {
      const boundary = 'monhub-boundary-7f3a';
      final meta = jsonEncode({
        'name': name,
        'mimeType': ?convertTo,
        if (parent != null) 'parents': [parent],
      });
      final body = BytesBuilder()
        ..add(utf8.encode('--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n$meta\r\n'))
        ..add(utf8.encode('--$boundary\r\nContent-Type: $mime\r\n\r\n'))
        ..add(data)
        ..add(utf8.encode('\r\n--$boundary--'));
      res = await http.post(
        Uri.parse('https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=$fields'),
        headers: {'Authorization': 'Bearer $token', 'Content-Type': 'multipart/related; boundary=$boundary'},
        body: body.toBytes(),
      );
    }
    if (res.statusCode >= 400) throw _error(res);
    return (jsonDecode(utf8.decode(res.bodyBytes)) as Map).cast<String, dynamic>();
  }

  static String _error(http.Response res) {
    try {
      final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map;
      final m = '${(j['error'] as Map?)?['message'] ?? res.statusCode}';
      if (m.contains('insufficient') || m.contains('scope')) {
        return 'Google : reconnecte ton compte pour autoriser Mon Hub à modifier ton Drive';
      }
      return 'Google : $m';
    } catch (_) {
      return 'Google : erreur ${res.statusCode}';
    }
  }

  /// Appel à une API Google au nom de [email].
  static Future<Map<String, dynamic>> api(String email, String method, String url, {Object? body}) async {
    final token = await accessToken(email);
    final req = http.Request(method, Uri.parse(url))..headers['Authorization'] = 'Bearer $token';
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    final res = await http.Response.fromStream(await req.send());
    if (res.statusCode == 204 || res.body.isEmpty) return {};
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode >= 400) {
      throw 'Google : ${(j['error'] as Map?)?['message'] ?? res.statusCode}';
    }
    return j;
  }
}
