import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';
import 'package:supabase/supabase.dart';

import '../module_store.dart';

/// Le serveur Supabase de Mon Hub (adresse + clé publique « anon »).
///
/// La clé « anon » n'est pas un secret : elle est faite pour être dans
/// l'appli. Ce sont les règles de la base (`supabase/schema.sql`) qui
/// protègent les données.
class OnlineServer {
  const OnlineServer(this.url, this.key);
  final String url;
  final String key;

  static const _prefix = 'MONHUB-SERVEUR:';

  /// Adresse propre (https, sans « / » final) ou null si elle ne va pas.
  static String? cleanUrl(String raw) {
    var u = raw.trim();
    if (u.isEmpty) return null;
    if (!u.startsWith('http')) u = 'https://$u';
    final uri = Uri.tryParse(u);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty || !uri.host.contains('.')) return null;
    return 'https://${uri.host}${uri.hasPort && uri.port != 443 ? ':${uri.port}' : ''}';
  }

  /// Une clé « anon » ressemble à un jeton JWT (trois morceaux) ou à une
  /// clé publiable « sb_publishable_… ».
  static bool looksLikeKey(String k) {
    final t = k.trim();
    return RegExp(r'^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$').hasMatch(t) ||
        RegExp(r'^sb_publishable_[A-Za-z0-9_-]{10,}$').hasMatch(t);
  }

  /// Code à envoyer à ses amis (ou à son autre appareil) pour utiliser le
  /// même serveur.
  String get code => '$_prefix${base64Url.encode(utf8.encode(jsonEncode({'u': url, 'k': key})))}';

  static OnlineServer? fromCode(String text) {
    final i = text.indexOf(_prefix);
    if (i < 0) return null;
    final raw = text.substring(i + _prefix.length).trim().split(RegExp(r'\s')).first;
    try {
      final j = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(raw)))) as Map;
      final u = cleanUrl('${j['u'] ?? ''}');
      final k = '${j['k'] ?? ''}'.trim();
      if (u == null || !looksLikeKey(k)) return null;
      return OnlineServer(u, k);
    } catch (_) {
      return null;
    }
  }

  Map<String, String> toJson() => {'u': url, 'k': key};
}

/// **Mon Hub en ligne** : un compte (adresse mail + mot de passe) pour
/// retrouver tout son Mon Hub sur n'importe quel appareil, et partager des
/// espaces, des tâches et des discussions avec d'autres comptes.
///
/// * Le mot de passe ne part jamais tel quel : le serveur reçoit seulement
///   une empreinte ([authPassword]). La copie du compte, elle, est chiffrée
///   avec une clé tirée du vrai mot de passe : le serveur ne peut pas la lire.
/// * Le serveur est **ton** projet Supabase (gratuit) : voir
///   `docs/SUPABASE.md`. Son adresse vient de la construction de l'appli
///   (`SUPABASE_URL` / `SUPABASE_ANON_KEY`) ou des réglages ([setServer]).
class Online extends ChangeNotifier {
  Online._();
  static final instance = Online._();

  static const _builtUrl = String.fromEnvironment('SUPABASE_URL');
  static const _builtKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  /// Serveur choisi sur cet appareil (tous les comptes Mon Hub d'ici).
  static const _serverKey = 'app.online.server';

  /// Session gardée pour le compte Mon Hub connecté (jamais synchronisée :
  /// chaque appareil a la sienne).
  static const _sessionKey = 'sync.online.session';

  /// Préfixe du « compte » de la synchro quand la copie est en ligne.
  static const syncPrefix = 'monhub:';

  /// Le serveur, ou null s'il n'est pas encore réglé.
  OnlineServer? get server {
    if (_builtUrl.isNotEmpty && _builtKey.isNotEmpty) return const OnlineServer(_builtUrl, _builtKey);
    try {
      final raw = ModuleStore.global.getString(_serverKey);
      if (raw == null) return null;
      final j = jsonDecode(raw) as Map;
      final u = OnlineServer.cleanUrl('${j['u'] ?? ''}');
      final k = '${j['k'] ?? ''}';
      return u == null || k.isEmpty ? null : OnlineServer(u, k);
    } catch (_) {
      return null;
    }
  }

  bool get configured => server != null;

  /// Le serveur vient-il de la construction de l'appli (rien à régler) ?
  bool get builtIn => _builtUrl.isNotEmpty && _builtKey.isNotEmpty;

  Future<void> setServer(OnlineServer s) async {
    await ModuleStore.global.setString(_serverKey, jsonEncode(s.toJson()));
    await _drop();
    notifyListeners();
  }

  Future<void> clearServer() async {
    await signOut();
    await ModuleStore.global.remove(_serverKey);
    await _drop();
    notifyListeners();
  }

  @visibleForTesting
  static const authOptions = AuthClientOptions(authFlowType: AuthFlowType.implicit);

  SupabaseClient? _client;
  OnlineServer? _clientFor;
  StreamSubscription<AuthState>? _authSub;

  /// Espace (compte Mon Hub) auquel la session appartient.
  String? _profile;

  /// Le client Supabase (null : pas de serveur).
  SupabaseClient? get clientOrNull {
    final s = server;
    if (s == null) return null;
    final c = _client;
    if (c != null && _clientFor?.url == s.url && _clientFor?.key == s.key) return c;
    unawaited(_authSub?.cancel());
    unawaited(c?.dispose());
    // Connexion par mot de passe seulement : le mode PKCE (par défaut) exige un
    // stockage que le client Dart pur n'a pas → « Null check operator » à la
    // création du compte (signUp).
    final n = SupabaseClient(s.url, s.key, authOptions: authOptions);
    _client = n;
    _clientFor = s;
    _authSub = n.auth.onAuthStateChange.listen(_onAuth, onError: (Object _) {});
    return n;
  }

  /// Le client, connecté (sinon une erreur claire).
  SupabaseClient get db {
    final c = clientOrNull;
    if (c == null) throw 'Mon Hub en ligne n\'est pas encore réglé (Réglages → Compte en ligne).';
    if (c.auth.currentUser == null) throw 'Connecte ton compte en ligne (Réglages → Compte en ligne).';
    return c;
  }

  User? get user => _client?.auth.currentUser;
  bool get signedIn => user != null;
  String? get email => user?.email;
  String? get userId => user?.id;

  /// « Compte » de la synchro (voir [AccountSync]) pour cette adresse.
  static String syncMail(String email) => '$syncPrefix${email.trim().toLowerCase()}';
  static bool isSyncMail(String? mail) => mail != null && mail.startsWith(syncPrefix);

  /// Ce que le serveur reçoit à la place du mot de passe.
  static String authPassword(String email, String password) =>
      sha256.convert(utf8.encode('monhub-auth|${email.trim().toLowerCase()}|$password')).toString();

  void _onAuth(AuthState s) {
    final profile = _profile;
    // Pas de compte Mon Hub ouvert (ou un autre entre-temps) : on ne range rien.
    if (profile == null || profile != ModuleStore.profile) return;
    final session = s.session;
    if (s.event == AuthChangeEvent.signedOut) {
      unawaited(ModuleStore.deleteSecretRaw(_sessionKey).catchError((Object _) {}));
    } else if (session != null) {
      unawaited(ModuleStore.writeSecretRaw(_sessionKey, jsonEncode(session.toJson())).catchError((Object _) {}));
    }
    notifyListeners();
  }

  /// Compte Mon Hub ouvert (ou nouvel appareil en train de se connecter) :
  /// reprend sa session en ligne.
  Future<void> open() async {
    _profile = ModuleStore.profile;
    final c = clientOrNull;
    if (c == null) return;
    String? raw;
    try {
      raw = await ModuleStore.readSecretRaw(_sessionKey);
    } catch (_) {}
    if (raw == null) {
      // Rien de gardé pour ce compte (le client vient d'être recréé : personne
      // d'autre n'y est connecté).
      notifyListeners();
      return;
    }
    try {
      await c.auth.recoverSession(raw);
    } on AuthException catch (e) {
      // Session expirée ou révoquée : il faudra se reconnecter.
      if (e.statusCode == '400' || e.statusCode == '401' || e.statusCode == '403') {
        await ModuleStore.deleteSecretRaw(_sessionKey).catchError((Object _) {});
      }
    } catch (_) {
      // Pas d'internet : on réessaiera.
    }
    notifyListeners();
  }

  /// Compte Mon Hub fermé : la session reste gardée, mais plus utilisée ici.
  Future<void> close() async {
    _profile = null;
    await _drop();
  }

  Future<void> _drop() async {
    final c = _client;
    _client = null;
    _clientFor = null;
    await _authSub?.cancel();
    _authSub = null;
    try {
      await c?.dispose();
    } catch (_) {}
  }

  /// Connexion avec l'adresse et le mot de passe (Mon Hub).
  Future<void> signIn(String email, String password) async {
    final c = clientOrNull;
    if (c == null) throw 'Mon Hub en ligne n\'est pas encore réglé.';
    _profile = ModuleStore.profile;
    try {
      await c.auth.signInWithPassword(email: email.trim().toLowerCase(), password: authPassword(email, password));
    } catch (e) {
      throw explain(e);
    }
    notifyListeners();
  }

  /// Création du compte en ligne. Renvoie false s'il faut d'abord confirmer
  /// l'adresse (mail envoyé par Supabase).
  Future<bool> signUp(String email, String password, {String name = ''}) async {
    final c = clientOrNull;
    if (c == null) throw 'Mon Hub en ligne n\'est pas encore réglé.';
    _profile = ModuleStore.profile;
    AuthResponse r;
    try {
      r = await c.auth.signUp(
        email: email.trim().toLowerCase(),
        password: authPassword(email, password),
        data: {if (name.trim().isNotEmpty) 'name': name.trim()},
      );
    } catch (e) {
      throw explain(e);
    }
    notifyListeners();
    return r.session != null;
  }

  /// Se connecte, ou crée le compte s'il n'existe pas encore. Renvoie false
  /// s'il faut confirmer l'adresse.
  Future<bool> signInOrUp(String email, String password, {String name = ''}) async {
    try {
      await signIn(email, password);
      return true;
    } catch (e) {
      if ('$e' != _wrongCredentials) rethrow;
    }
    try {
      return await signUp(email, password, name: name);
    } catch (e) {
      // Le compte existe déjà, avec un autre mot de passe.
      if ('$e' == _alreadyThere) throw _wrongCredentials;
      rethrow;
    }
  }

  Future<void> signOut() async {
    try {
      await _client?.auth.signOut();
    } catch (_) {}
    try {
      await ModuleStore.deleteSecretRaw(_sessionKey);
    } catch (_) {}
    notifyListeners();
  }

  static const _wrongCredentials = 'Adresse ou mot de passe incorrect.';
  static const _alreadyThere = 'Ce compte en ligne existe déjà : connecte-toi.';

  /// Une erreur du serveur, dite simplement.
  static String explain(Object e) {
    if (e is String) return e;
    if (e is SocketException || e is TimeoutException) return 'Pas d\'internet pour le moment.';
    if (e is AuthException) {
      final m = e.message.toLowerCase();
      if (m.contains('invalid login') || m.contains('invalid credentials')) return _wrongCredentials;
      if (m.contains('not confirmed')) {
        return 'Confirme d\'abord ton adresse : ouvre le mail envoyé par Supabase, clique le lien, puis réessaie.';
      }
      if (m.contains('already registered') || m.contains('already exists')) return _alreadyThere;
      if (m.contains('rate limit') || e.statusCode == '429') return 'Trop d\'essais : attends une minute.';
      if (m.contains('signups not allowed') || m.contains('signup is disabled')) {
        return 'Les inscriptions sont fermées sur ce serveur (Supabase → Authentication → Sign In / Providers).';
      }
      if (m.contains('valid email') || m.contains('invalid format')) return 'Cette adresse mail n\'est pas valide.';
      return 'Connexion : ${e.message}';
    }
    if (e is PostgrestException) {
      final m = e.message.toLowerCase();
      if (e.code == '42P01' || e.code == 'PGRST202' || e.code == 'PGRST205' || m.contains('does not exist')) {
        return 'La base n\'est pas prête : colle le fichier supabase/schema.sql dans Supabase (SQL Editor → Run).';
      }
      if (m.contains('code inconnu')) return 'Ce code d\'invitation n\'existe pas (ou a été changé).';
      if (m.contains('personne introuvable')) return 'Personne n\'a ce pseudo.';
      if (m.contains('c\'est toi')) return 'C\'est ton propre pseudo.';
      if (e.code == '23505') return 'Ce pseudo est déjà pris.';
      if (e.code == '23514') return 'Ce n\'est pas accepté (trop long, ou caractères interdits).';
      if (e.code == '42501' || m.contains('row-level security')) return 'Tu n\'as pas le droit de faire ça ici.';
      return 'Serveur : ${e.message}';
    }
    final s = '$e';
    if (s.contains('SocketException') || s.contains('Failed host lookup')) return 'Pas d\'internet pour le moment.';
    return s;
  }

  // ---------- Profil (nom affiché + @pseudo) ----------

  /// Un @pseudo valable (3 à 30 lettres minuscules, chiffres, . _ -).
  static String? cleanHandle(String raw) {
    final h = raw.trim().toLowerCase().replaceAll(RegExp(r'^@+'), '');
    return RegExp(r'^[a-z0-9._-]{3,30}$').hasMatch(h) ? h : null;
  }

  /// Pseudo proposé à partir d'un nom ou d'une adresse.
  static String suggestHandle(String from) {
    const a = 'àâäáãåçéèêëíìîïñóòôöõúùûüýÿ';
    const b = 'aaaaaaceeeeiiiinooooouuuuyy';
    final base = from.split('@').first.toLowerCase().split('').map((c) {
      final i = a.indexOf(c);
      return i < 0 ? c : b[i];
    }).join();
    var h = base.replaceAll(RegExp(r'[^a-z0-9._-]+'), '');
    if (h.length < 3) h = '${h}hub';
    return h.length > 30 ? h.substring(0, 30) : h;
  }

  Map<String, dynamic>? profile;

  Future<Map<String, dynamic>?> loadProfile() async {
    final id = userId;
    if (id == null) return null;
    try {
      profile = await db.from('profiles').select().eq('id', id).maybeSingle();
    } catch (_) {}
    notifyListeners();
    return profile;
  }

  Future<void> saveProfile({required String name, required String handle}) async {
    final id = userId;
    if (id == null) throw 'Connecte ton compte en ligne.';
    final h = cleanHandle(handle);
    if (h == null) throw 'Pseudo : 3 à 30 lettres, chiffres, point, tiret ou _.';
    try {
      profile = await db
          .from('profiles')
          .upsert({'id': id, 'name': name.trim(), 'handle': h})
          .select()
          .single();
    } catch (e) {
      throw explain(e);
    }
    notifyListeners();
  }
}
