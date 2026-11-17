import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

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

  static const clientId = String.fromEnvironment('GOOGLE_CLIENT_ID');
  static const clientSecret = String.fromEnvironment('GOOGLE_CLIENT_SECRET');
  static bool get available => clientId.isNotEmpty;

  static const scopes = [
    'openid',
    'email',
    'https://mail.google.com/',
    'https://www.googleapis.com/auth/calendar',
    // Lecture de ton Drive (dossiers, fichiers, aperçus) pour le module Drive.
    'https://www.googleapis.com/auth/drive.readonly',
  ];

  static final ModuleStore store = ModuleStore()..bind('google');

  /// Comptes Google connectés (adresses).
  static List<String> get accounts =>
      (store.getJson<List<dynamic>>('accounts') ?? const []).cast<String>();

  static final _tokens = <String, (String, DateTime)>{};

  static String _rand(int n) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final r = Random.secure();
    return List.generate(n, (_) => chars[r.nextInt(chars.length)]).join();
  }

  /// Ouvre la page Google et renvoie l'adresse du compte connecté.
  static Future<String> signIn() async {
    if (!available) throw 'La connexion Google n\'est pas encore activée dans cette version';
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirect = 'http://127.0.0.1:${server.port}';
    final verifier = _rand(64);
    final challenge = base64Url
        .encode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');
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
      if (!await Browser.open(url.toString())) {
        throw 'Impossible d\'ouvrir le navigateur';
      }
      final code =
          await () async {
            await for (final req in server) {
              final q = req.uri.queryParameters;
              if (q['state'] != state && q['code'] == null && q['error'] == null) {
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
          }().timeout(
            const Duration(minutes: 5),
            onTimeout: () => throw 'Temps dépassé : recommence la connexion Google',
          );

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
      _tokens[email] = (
        access,
        DateTime.now().add(Duration(seconds: (j['expires_in'] as int) - 60)),
      );
      await store.setJson('accounts', {...accounts, email}.toList());
      return email;
    } finally {
      await server.close(force: true);
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
    return access;
  }

  /// Appel à une API Google au nom de [email].
  static Future<Map<String, dynamic>> api(
    String email,
    String method,
    String url, {
    Object? body,
  }) async {
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
