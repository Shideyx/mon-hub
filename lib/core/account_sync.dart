import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' show Random;
import 'dart:typed_data' show BytesBuilder;

import 'package:archive/archive.dart' show GZipDecoder, GZipEncoder;
import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'google_auth.dart';
import 'hub_files.dart';
import 'module_store.dart';
import 'session.dart';
import 'vault.dart';

/// Ton compte Mon Hub sur tous tes appareils, **sans export**.
///
/// Une copie du compte (réglages, modules, connexions, historiques,
/// carnet, révisions…) est gardée dans **ton** Google Drive, dans le dossier
/// « Mon Hub - compte synchronisé ». Elle est chiffrée (AES-256-GCM) avec une
/// clé tirée de ton mot de passe Mon Hub : Google ne peut pas la lire, et
/// Mon Hub n'a toujours **aucun serveur**.
///
/// Sur un autre appareil : page de connexion → « Retrouver mon compte » →
/// même compte Google → ton mot de passe Mon Hub, et tout est là. Si l'autre
/// PC n'a pas activé la synchro (et que tu n'y as pas accès), le nouvel
/// appareil dépose une **demande** dans le Drive : Mon Hub, ouvert sur l'autre
/// PC, la voit et envoie le compte tout seul ([answerRequests]).
///
/// Chaque appareil fusionne ses changements avec ceux des autres toutes les
/// quelques minutes, réglage par réglage et fichier par fichier : le plus
/// récent gagne, rien n'est écrasé en bloc.
class AccountSync extends ChangeNotifier {
  AccountSync._();
  static final instance = AccountSync._();

  /// Où est gardée la copie (tests : en mémoire).
  static SyncCloud Function(String email) cloudFor = DriveFolder.new;

  /// Rythme de la synchro quand Mon Hub est ouvert.
  static const every = Duration(minutes: 3);

  /// Rythme de la recherche des demandes d'un autre appareil.
  static const watchEvery = Duration(minutes: 5);

  // Réglages de la synchro : propres à cet appareil, jamais synchronisés.
  static const _emailKey = 'sync.email';
  static const _versionKey = 'sync.version';
  static const _lastKey = 'sync.last';
  static const _keyName = 'sync.key';

  /// Nom de la copie dans le Drive.
  static String fileName(String login) => 'compte-$login.monhub';

  /// Nom de la demande déposée par un nouvel appareil.
  static String requestName(String login) => 'demande-compte-$login.json';

  /// Compte Google qui garde la copie (null : synchro désactivée).
  String? get email => ModuleStore.prefs.getString(_emailKey);
  bool get enabled => email != null;

  DateTime? get lastSync => DateTime.tryParse(ModuleStore.prefs.getString(_lastKey) ?? '');

  bool busy = false;

  /// Dernière erreur (internet coupé, Google déconnecté…).
  String? error;

  /// La copie du Drive a été chiffrée avec un autre mot de passe (changé
  /// ailleurs) : il faut le retaper une fois.
  bool needsPassword = false;

  /// Prévenu quand des données venues d'un autre appareil ont été écrites
  /// ici (clés « p:… » réglages, « s:… » connexions, « f:… » fichiers).
  void Function(Set<String> keys)? onApplied;

  /// Pour prévenir la personne (notification) : compte envoyé à la demande
  /// d'un autre appareil.
  void Function(String title, String body)? onNotice;

  /// Ce que la dernière synchro a vu (empreintes + dates, aucune valeur).
  final _base = JsonFile<Map<String, dynamic>>(
    'sync-base.json',
    empty: () => {},
    decode: (j) => j is Map ? j.cast<String, dynamic>() : {},
    encode: (v) => v,
  );

  Timer? _timer;
  Timer? _watch;

  /// Change à chaque arrêt : une synchro en cours s'arrête avant d'écrire.
  int _gen = 0;

  /// Espace du compte en train d'arriver (page de connexion).
  String? _joining;

  // ---------- Marche / arrêt ----------

  /// Compte ouvert (Mon Hub, pas les widgets ni Clicky partout) : synchro
  /// maintenant puis toutes les [every], et réponse aux demandes des autres
  /// appareils toutes les [watchEvery].
  void start() {
    stop();
    final gen = _gen;
    Future<void>.delayed(const Duration(seconds: 8), () async {
      if (gen != _gen) return;
      if (enabled) await syncNow();
      if (gen == _gen) await answerRequests();
    });
    _watch = Timer.periodic(watchEvery, (_) => unawaited(answerRequests()));
    if (enabled) _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer.periodic(every, (_) => unawaited(syncNow()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _watch?.cancel();
    _watch = null;
    _gen++;
    error = null;
    needsPassword = false;
  }

  // ---------- Synchro ----------

  /// Fusionne cet appareil avec la copie du Drive (sans jamais lever
  /// d'erreur : elle est gardée dans [error]).
  Future<void> syncNow() async {
    final acc = AppSession.instance.current;
    final mail = email;
    if (acc == null || mail == null || busy) return;
    final key = await _loadKey() ?? await _freshKey(acc);
    await _guard(() => _sync(acc, mail, key));
  }

  Future<void> _guard(Future<void> Function() work, {bool rethrowError = false}) async {
    busy = true;
    notifyListeners();
    try {
      await work();
      error = null;
      needsPassword = false;
    } on WrongPassword {
      needsPassword = true;
      if (rethrowError) rethrow;
    } catch (e) {
      error = '$e';
      if (rethrowError) rethrow;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> _sync(HubAccount acc, String mail, SyncKey key, {bool remoteWins = false}) async {
    final gen = _gen;
    final profile = ModuleStore.profile;
    bool still() => gen == _gen && ModuleStore.profile == profile;

    final cloud = cloudFor(mail);
    final name = fileName(acc.login);
    final local = await collect();
    final base = SyncMerge.readStamps(await _base.load());
    final now = DateTime.now().millisecondsSinceEpoch;
    final stamped = remoteWins && base.isEmpty
        // Nouvel appareil : ce qui est dans le Drive l'emporte.
        ? {for (final e in local.values.entries) e.key: SyncEntry(e.value, 0, local.hashes[e.key])}
        : SyncMerge.stamp(local.values, base, now, hashes: local.hashes);
    // Fichier illisible ici (clé perdue) : la copie du Drive fait foi.
    stamped.removeWhere((k, _) => local.unreadable.contains(k));
    SyncMerge.checkNotWiped(stamped, base);

    final copy = (await cloud.list()).where((c) => c.name == name).firstOrNull;
    final seen = ModuleStore.prefs.getString(_versionKey);
    Map<String, SyncEntry>? remote;
    if (copy == null) {
      remote = {};
    } else if (copy.version != seen || base.isEmpty || local.unreadable.isNotEmpty) {
      final h = SyncBox.header(await cloud.read(copy.id));
      try {
        remote = (await SyncBox.open(h, key, acc.login)).entries;
      } on WrongPassword {
        // Copie refaite ailleurs avec le même mot de passe (autre sel) : on
        // retrouve la clé sans rien demander.
        if (h.accountSalt != acc.salt) rethrow;
        key = await SyncKey.forAccount(acc, salt: h.salt, iterations: h.iterations);
        remote = (await SyncBox.open(h, key, acc.login)).entries;
        await _saveKey(key);
      }
    }
    // remote == null : la copie n'a pas bougé depuis la dernière synchro.
    final merged = SyncMerge.prune(remote == null ? stamped : SyncMerge.merge(stamped, remote), now);
    if (!still()) return;
    final changed = await _apply(merged, stamped, still);
    if (!still()) return;
    final upload = copy == null ||
        (remote == null ? !SyncMerge.sameAsStamps(merged, base) : !SyncMerge.same(merged, remote));
    var version = copy?.version;
    if (upload) {
      final text = await SyncBox.seal(login: acc.login, account: acc, key: key, entries: merged);
      if (!still()) return;
      version = (await cloud.write(name, text, id: copy?.id)).version;
    }
    await _base.save(SyncMerge.toStamps(merged));
    await ModuleStore.prefs.setString(_versionKey, version ?? '');
    await ModuleStore.prefs.setString(_lastKey, DateTime.now().toIso8601String());
    if (changed.isNotEmpty) onApplied?.call(changed);
  }

  // ---------- Activer / arrêter (Réglages) ----------

  /// Active la synchro du compte connecté avec le Drive de [mail].
  Future<void> enable({required String mail}) async {
    final acc = AppSession.instance.current;
    if (acc == null) throw 'Connecte-toi d\'abord';
    try {
      await _guard(rethrowError: true, () => _enable(acc, mail));
    } finally {
      // Même si internet a coupé : on réessaiera tout seul.
      if (enabled) _schedule();
    }
  }

  Future<void> _enable(HubAccount acc, String mail) async {
    final cloud = cloudFor(mail);
    final copy = (await cloud.list()).where((c) => c.name == fileName(acc.login)).firstOrNull;
    SyncKey key;
    if (copy != null) {
      // Déjà gardé (autre appareil, ou synchro réactivée) : même clé.
      final h = SyncBox.header(await cloud.read(copy.id));
      key = await SyncKey.forAccount(acc, salt: h.salt, iterations: h.iterations);
      try {
        await SyncBox.open(h, key, acc.login);
      } on WrongPassword {
        throw 'Une copie du compte « ${acc.login} » existe déjà dans ce Google Drive, '
            'avec un autre mot de passe.';
      }
    } else {
      key = await SyncKey.forAccount(acc);
    }
    await _saveKey(key);
    await ModuleStore.prefs.setString(_emailKey, mail);
    await ModuleStore.prefs.remove(_versionKey);
    await _base.save({});
    await _sync(acc, mail, key);
  }

  /// Arrête la synchro sur cet appareil ([deleteCopy] : supprime aussi la
  /// copie du Drive).
  Future<void> disable({bool deleteCopy = false}) async {
    final mail = email;
    final acc = AppSession.instance.current;
    stop();
    if (deleteCopy && mail != null && acc != null) {
      final cloud = cloudFor(mail);
      for (final c in await cloud.list()) {
        if (c.name == fileName(acc.login)) await cloud.delete(c.id);
      }
    }
    for (final k in [_emailKey, _versionKey, _lastKey]) {
      await ModuleStore.prefs.remove(k);
    }
    await ModuleStore.deleteSecretRaw(_keyName);
    await _base.save({});
    // Les demandes des autres appareils restent surveillées.
    if (acc != null) _watch ??= Timer.periodic(watchEvery, (_) => unawaited(answerRequests()));
    notifyListeners();
  }

  /// Mot de passe retapé (copie chiffrée ailleurs avec un autre mot de passe).
  Future<void> unlock(String password) async {
    final acc = AppSession.instance.current;
    final mail = email;
    if (acc == null || mail == null) return;
    if (!AppSession.instance.checkPassword(password)) throw 'Mot de passe incorrect';
    final cloud = cloudFor(mail);
    final copy = (await cloud.list()).where((c) => c.name == fileName(acc.login)).firstOrNull;
    SyncKey key;
    if (copy == null) {
      key = await SyncKey.forAccount(acc);
    } else {
      final h = SyncBox.header(await cloud.read(copy.id));
      key = await SyncKey.fromPassword(h, password);
      try {
        await SyncBox.open(h, key, acc.login);
      } on WrongPassword {
        throw 'La copie du Drive a un autre mot de passe : tape celui que tu utilises sur ton autre appareil.';
      }
    }
    await _saveKey(key);
    needsPassword = false;
    await syncNow();
  }

  /// Juste après « Se connecter » : reprend la synchro si elle attendait le
  /// mot de passe.
  Future<void> afterSignIn(String password) async {
    if (!enabled || !needsPassword) return;
    try {
      await unlock(password);
    } catch (_) {}
  }

  // ---------- Demandes d'un autre appareil ----------

  /// Un autre appareil a demandé ce compte (fichier « demande » déposé dans
  /// le Drive, donc par quelqu'un qui a accès à ce compte Google) : on lui
  /// envoie, même si personne n'est devant ce PC. La copie est chiffrée : il
  /// faut le mot de passe Mon Hub pour l'ouvrir.
  Future<void> answerRequests() async {
    final acc = AppSession.instance.current;
    if (acc == null || busy || _joining != null) return;
    for (final mail in GoogleAuth.accounts.where(GoogleAuth.canWriteDrive)) {
      try {
        final cloud = cloudFor(mail);
        final asks = [for (final c in await cloud.list()) if (c.name == requestName(acc.login)) c];
        if (asks.isEmpty) continue;
        final was = enabled;
        if (!was) {
          await enable(mail: mail);
        } else if (email == mail) {
          await syncNow();
        } else {
          // La copie est gardée dans un autre compte Google.
          continue;
        }
        if (error != null || needsPassword) return;
        for (final a in asks) {
          await cloud.delete(a.id);
        }
        if (!was) {
          onNotice?.call(
            'Compte envoyé à ton autre appareil',
            'Un autre appareil a demandé ton compte « ${acc.login} » : il est maintenant dans ton '
                'Google Drive ($mail), chiffré avec ton mot de passe, et reste synchronisé. '
                'Réglages → Mes appareils pour arrêter.',
          );
        }
        return;
      } catch (_) {}
    }
  }

  /// Nouvel appareil : dépose une demande du compte [login] dans le Drive
  /// de [mail] (Mon Hub, ouvert sur l'autre PC, y répond tout seul).
  static Future<void> requestCopy(String mail, String login) async {
    final id = AppSession.normalize(login);
    if (!RegExp(r'^[a-z0-9._-]{3,}$').hasMatch(id)) throw 'Tape ton identifiant Mon Hub';
    final cloud = cloudFor(mail);
    final old = (await cloud.list()).where((c) => c.name == requestName(id)).firstOrNull;
    await cloud.write(
      requestName(id),
      jsonEncode({'app': 'mon-hub-demande', 'identifiant': id, 'demande': DateTime.now().toUtc().toIso8601String()}),
      id: old?.id,
    );
  }

  // ---------- Nouvel appareil (page de connexion) ----------

  /// Prépare l'espace du compte qui va arriver : la connexion Google faite
  /// pour le retrouver s'y range directement.
  void beginJoin() {
    if (_joining != null && ModuleStore.profile == _joining) return;
    _joining = AppSession.newNamespace();
    ModuleStore.profile = _joining!;
  }

  /// Abandon : on efface ce qui a été préparé.
  Future<void> cancelJoin() async {
    final ns = _joining;
    _joining = null;
    if (ns == null || !ns.startsWith('p.') || AppSession.instance.current?.ns == ns) return;
    // L'appli revient tout de suite à la page de connexion normale…
    if (AppSession.instance.current == null && ModuleStore.profile == ns) ModuleStore.profile = '';
    // … puis on efface ce qui avait été préparé.
    try {
      final global = ModuleStore.global;
      for (final k in global.getKeys().where((k) => k.startsWith(ns)).toList()) {
        await global.remove(k);
      }
      final secrets = await ModuleStore.secure.readAll();
      for (final k in secrets.keys.where((k) => k.startsWith(ns))) {
        await ModuleStore.secure.delete(key: k);
      }
      final d = await HubFiles.dirOf(ns);
      if (d != null && await d.exists()) await d.delete(recursive: true);
    } catch (_) {}
  }

  /// Les comptes Mon Hub gardés dans le Drive de [mail].
  static Future<List<CloudCopy>> copies(String mail) async =>
      [for (final c in await cloudFor(mail).list()) if (c.login != null) c];

  /// Récupère le compte [copy] (gardé dans le Drive de [mail]) sur cet
  /// appareil, puis l'ouvre.
  Future<void> join({required String mail, required CloudCopy copy, required String password}) async {
    final login = copy.login;
    if (login == null) throw 'Ce n\'est pas un compte Mon Hub';
    if (AppSession.instance.accounts.containsKey(login)) {
      throw 'Le compte « $login » existe déjà sur cet appareil : connecte-toi avec, '
          'puis Réglages → Mes appareils.';
    }
    beginJoin();
    final ns = ModuleStore.profile;
    final cloud = cloudFor(mail);
    final h = SyncBox.header(await cloud.read(copy.id));
    final key = await SyncKey.fromPassword(h, password);
    final opened = await SyncBox.open(h, key, login);
    final a = opened.account;
    final name = '${a['nom'] ?? login}';
    var salt = '${a['sel'] ?? ''}';
    var hash = '${a['empreinte'] ?? ''}';
    if (salt.isEmpty || AppSession.passwordHash(salt, password) != hash) {
      salt = AppSession.newSalt();
      hash = AppSession.passwordHash(salt, password);
    }
    final acc = HubAccount(login, name, ns, salt, hash);
    await _saveKey(key);
    await ModuleStore.prefs.setString(_emailKey, mail);
    await _base.save({});
    await _guard(rethrowError: true, () => _sync(acc, mail, key, remoteWins: true));
    // La demande éventuelle a servi.
    try {
      for (final c in await cloud.list()) {
        if (c.name == requestName(login)) await cloud.delete(c.id);
      }
    } catch (_) {}
    await AppSession.instance.adopt(acc);
    _joining = null;
  }

  // ---------- Données du compte ----------

  static const _localPrefs = ['sync.', 'app.', 'shortcut.', 'hub.detached'];

  /// Réglage synchronisé (pas ceux propres à ce PC : widgets posés sur le
  /// bureau, raccourcis, réglages de la synchro elle-même).
  static bool syncedPref(String k) => !_localPrefs.any(k.startsWith);

  /// Connexion synchronisée (pas la clé du coffre de cet appareil).
  static bool syncedSecret(String k) => k != 'vault.key' && !k.startsWith('sync.');

  /// Fichier synchronisé (pas les journaux de rangement, propres à ce PC).
  static bool syncedFile(String name) =>
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*\.json$').hasMatch(name) &&
      !name.startsWith('rangement-') &&
      !name.startsWith('sync-');

  /// Fichiers déjà lus : (date de modification, contenu, empreinte). Un
  /// historique qui n'a pas bougé n'est ni relu, ni redéchiffré.
  static final _files = <String, (DateTime, String, String)>{};

  /// Tout ce qui fait le compte sur cet appareil.
  @visibleForTesting
  static Future<LocalData> collect() async {
    final values = <String, Object>{};
    final hashes = <String, String>{};
    final unreadable = <String>{};
    final prefs = ModuleStore.prefs;
    for (final k in prefs.getKeys()) {
      if (!syncedPref(k)) continue;
      final v = prefs.get(k);
      if (v != null) values['p:$k'] = v;
    }
    for (final e in (await ModuleStore.readAllSecrets()).entries) {
      if (syncedSecret(e.key)) values['s:${e.key}'] = e.value;
    }
    final dir = await HubFiles.dir();
    if (dir != null) {
      await for (final f in dir.list()) {
        if (f is! File) continue;
        final name = f.path.split(Platform.pathSeparator).last;
        if (!syncedFile(name)) continue;
        try {
          final modified = (await f.stat()).modified;
          final hit = _files[f.path];
          if (hit != null && hit.$1 == modified) {
            values['f:$name'] = hit.$2;
            hashes['f:$name'] = hit.$3;
            continue;
          }
          final text = await Vault.open(await f.readAsString());
          final hash = text.length > 200000
              ? await Isolate.run(() => SyncEntry.hashOf(text)!)
              : SyncEntry.hashOf(text)!;
          _files[f.path] = (modified, text, hash);
          values['f:$name'] = text;
          hashes['f:$name'] = hash;
        } catch (_) {
          unreadable.add('f:$name');
        }
      }
    }
    return LocalData(values, unreadable, hashes);
  }

  /// Écrit ici ce qui vient des autres appareils.
  static Future<Set<String>> _apply(
    Map<String, SyncEntry> merged,
    Map<String, SyncEntry> mine,
    bool Function() still,
  ) async {
    final changed = <String>{};
    final prefs = ModuleStore.prefs;
    Directory? dir;
    for (final e in merged.entries) {
      if (!still()) break;
      final k = e.key;
      final v = e.value.value;
      final cur = mine[k];
      final have = cur?.value;
      if (v == null ? have == null : have != null && (identical(have, v) || cur!.hash == e.value.hash)) continue;
      final id = k.length > 2 ? k.substring(2) : '';
      try {
        if (k.startsWith('p:') && syncedPref(id)) {
          await _setPref(prefs, id, v);
        } else if (k.startsWith('s:') && syncedSecret(id)) {
          v is String ? await ModuleStore.writeSecretRaw(id, v) : await ModuleStore.deleteSecretRaw(id);
        } else if (k.startsWith('f:') && syncedFile(id)) {
          dir ??= await HubFiles.dir();
          if (dir == null) continue;
          final f = File('${dir.path}${Platform.pathSeparator}$id');
          if (v is String) {
            final tmp = File('${f.path}.sync.tmp');
            await tmp.writeAsString(await Vault.seal(v), flush: true);
            await tmp.rename(f.path);
          } else if (await f.exists()) {
            await f.delete();
          }
        } else {
          continue;
        }
        changed.add(k);
      } catch (_) {}
    }
    return changed;
  }

  static Future<void> _setPref(ProfilePrefs p, String k, Object? v) async {
    if (v == null) {
      await p.remove(k);
    } else if (v is String) {
      await p.setString(k, v);
    } else if (v is bool) {
      await p.setBool(k, v);
    } else if (v is int) {
      await p.setInt(k, v);
    } else if (v is double) {
      await p.setDouble(k, v);
    } else if (v is List) {
      await p.setStringList(k, [for (final x in v) '$x']);
    }
  }

  // ---------- Clé de la copie ----------

  /// Pas encore de clé ici : celle du compte, sans rien demander.
  Future<SyncKey> _freshKey(HubAccount acc) async {
    final key = await SyncKey.forAccount(acc);
    await _saveKey(key);
    return key;
  }

  Future<SyncKey?> _loadKey() async {
    try {
      return SyncKey.parse(await ModuleStore.secure.read(key: '${ModuleStore.profile}$_keyName'));
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveKey(SyncKey key) => ModuleStore.writeSecretRaw(_keyName, key.toJson());
}

/// Ce que contient le compte sur cet appareil.
class LocalData {
  LocalData(this.values, this.unreadable, [this.hashes = const {}]);
  final Map<String, Object> values;

  /// Empreintes déjà connues (gros fichiers).
  final Map<String, String> hashes;

  /// Fichiers qu'on n'a pas pu ouvrir ici.
  final Set<String> unreadable;
}

/// Une valeur du compte et l'heure (ms) de son dernier changement.
/// [value] null : supprimée.
class SyncEntry {
  SyncEntry(this.value, this.time, [String? hash]) : _hash = hash;
  final Object? value;
  final int time;

  String? _hash;
  String? get hash => value == null ? null : _hash ??= hashOf(value);

  static String? hashOf(Object? v) => v == null ? null : sha256.convert(utf8.encode(jsonEncode(v))).toString();

  List<Object?> toJson() => [value, time, hash];
}

/// Empreinte + date d'une valeur, telle que vue à la dernière synchro.
typedef SyncStamp = ({String? hash, int time});

/// Fusion réglage par réglage : le plus récent gagne.
class SyncMerge {
  SyncMerge._();

  /// Une suppression est retenue 90 jours (le temps que tous les appareils
  /// l'aient vue).
  static const keepDeleted = Duration(days: 90);

  /// Date les valeurs de cet appareil : inchangée depuis la dernière synchro
  /// → elle garde sa date ; changée ou supprimée → [now].
  static Map<String, SyncEntry> stamp(
    Map<String, Object> local,
    Map<String, SyncStamp> base,
    int now, {
    Map<String, String> hashes = const {},
  }) {
    final out = <String, SyncEntry>{};
    for (final e in local.entries) {
      final b = base[e.key];
      final entry = SyncEntry(e.value, now, hashes[e.key]);
      out[e.key] = b != null && b.hash == entry.hash ? SyncEntry(e.value, b.time, entry.hash) : entry;
    }
    for (final e in base.entries) {
      if (local.containsKey(e.key)) continue;
      out[e.key] = SyncEntry(null, e.value.hash == null ? e.value.time : now);
    }
    return out;
  }

  /// [a] et [b] fusionnés : pour chaque clé, la plus récente (à égalité :
  /// celle de [b]).
  static Map<String, SyncEntry> merge(Map<String, SyncEntry> a, Map<String, SyncEntry> b) {
    final out = {...a};
    for (final e in b.entries) {
      final mine = out[e.key];
      if (mine == null || e.value.time >= mine.time) out[e.key] = e.value;
    }
    return out;
  }

  /// Oublie les suppressions anciennes.
  static Map<String, SyncEntry> prune(Map<String, SyncEntry> m, int now) => {
    for (final e in m.entries)
      if (e.value.value != null || now - e.value.time < keepDeleted.inMilliseconds) e.key: e.value,
  };

  static bool same(Map<String, SyncEntry> a, Map<String, SyncEntry> b) =>
      a.length == b.length &&
      a.entries.every((e) {
        final o = b[e.key];
        return o != null && o.time == e.value.time && o.hash == e.value.hash;
      });

  static bool sameAsStamps(Map<String, SyncEntry> a, Map<String, SyncStamp> b) =>
      a.length == b.length &&
      a.entries.every((e) {
        final o = b[e.key];
        return o != null && o.time == e.value.time && o.hash == e.value.hash;
      });

  static Map<String, Object?> toStamps(Map<String, SyncEntry> m) => {
    for (final e in m.entries) e.key: [e.value.hash, e.value.time],
  };

  static Map<String, SyncStamp> readStamps(Map<String, dynamic> j) => {
    for (final e in j.entries)
      if (e.value is List && (e.value as List).length == 2)
        e.key: (hash: (e.value as List)[0] as String?, time: ((e.value as List)[1] as num).toInt()),
  };

  /// Garde-fou : si presque tout le compte a disparu d'un coup de cet
  /// appareil (données effacées, disque changé…), on n'envoie pas ces
  /// suppressions aux autres.
  static void checkNotWiped(Map<String, SyncEntry> stamped, Map<String, SyncStamp> base) {
    final had = base.values.where((s) => s.hash != null).length;
    if (had < 10) return;
    final gone = stamped.entries.where((e) => e.value.value == null && base[e.key]?.hash != null).length;
    if (gone * 2 > had) {
      throw 'Une grande partie du compte a disparu de cet appareil : synchro mise en pause pour ne '
          'rien effacer ailleurs. Arrête puis réactive la synchro pour tout récupérer.';
    }
  }
}

/// Mauvais mot de passe (ou copie chiffrée avec un autre).
class WrongPassword implements Exception {
  const WrongPassword();
  @override
  String toString() => 'Mot de passe incorrect';
}

/// Clé de la copie (PBKDF2-SHA256). Tirée de l'empreinte du mot de passe
/// Mon Hub : l'appareil où le compte est ouvert la connaît (il peut donc
/// envoyer la copie sans qu'on lui retape le mot de passe) ; un nouvel
/// appareil la refait à partir du mot de passe tapé.
class SyncKey {
  SyncKey(this.salt, this.bytes, this.iterations, {this.accountSalt});
  final List<int> salt;
  final List<int> bytes;
  final int iterations;

  /// Sel du mot de passe du compte (null : ancienne clé, tirée du mot de
  /// passe lui-même, v1.48).
  final String? accountSalt;

  /// Assez lent pour rendre impossible de deviner le mot de passe.
  @visibleForTesting
  static int defaultIterations = 210000;

  static final _rnd = Random.secure();

  static Future<SyncKey> derive(String secret, {List<int>? salt, int? iterations, String? accountSalt}) async {
    final s = salt ?? List.generate(16, (_) => _rnd.nextInt(256));
    final it = iterations ?? defaultIterations;
    Future<List<int>> run() async {
      final k = await Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: it, bits: 256)
          .deriveKeyFromPassword(password: secret, nonce: s);
      return k.extractBytes();
    }

    List<int> bytes;
    try {
      // Calcul long : à côté, pour que l'appli ne se fige pas.
      bytes = await Isolate.run(run);
    } catch (_) {
      bytes = await run();
    }
    return SyncKey(s, bytes, it, accountSalt: accountSalt);
  }

  /// La clé d'un compte ouvert ici.
  static Future<SyncKey> forAccount(HubAccount acc, {List<int>? salt, int? iterations}) =>
      derive(acc.hash, salt: salt, iterations: iterations, accountSalt: acc.salt);

  /// Sur un nouvel appareil : la clé de la copie [h], à partir du mot de passe.
  static Future<SyncKey> fromPassword(SyncHeader h, String password) {
    final s = h.accountSalt;
    return s == null
        ? derive(password, salt: h.salt, iterations: h.iterations)
        : derive(AppSession.passwordHash(s, password), salt: h.salt, iterations: h.iterations, accountSalt: s);
  }

  String toJson() => jsonEncode({
    'sel': base64.encode(salt),
    'cle': base64.encode(bytes),
    'iterations': iterations,
    'compte': ?accountSalt,
  });

  static SyncKey? parse(String? raw) {
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw) as Map;
      return SyncKey(
        base64.decode('${j['sel']}'),
        base64.decode('${j['cle']}'),
        (j['iterations'] as num).toInt(),
        accountSalt: j['compte'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}

/// En-tête lisible d'une copie : l'identifiant et de quoi refaire la clé à
/// partir du mot de passe (rien qui permette de l'ouvrir sans lui).
class SyncHeader {
  SyncHeader(this.login, this.salt, this.iterations, this.data, [this.accountSalt]);
  final String login;
  final List<int> salt;
  final int iterations;
  final String data;
  final String? accountSalt;
}

/// Contenu déchiffré d'une copie.
class SyncContent {
  SyncContent(this.account, this.entries);

  /// Nom, sel et empreinte du mot de passe du compte.
  final Map<String, dynamic> account;
  final Map<String, SyncEntry> entries;
}

/// Le fichier gardé dans le Drive : compressé puis chiffré (AES-256-GCM).
class SyncBox {
  SyncBox._();

  static const app = 'mon-hub-compte';

  static Future<String> seal({
    required String login,
    required HubAccount account,
    required SyncKey key,
    required Map<String, SyncEntry> entries,
  }) async {
    final inner = jsonEncode({
      'compte': {'nom': account.name, 'sel': account.salt, 'empreinte': account.hash},
      'donnees': {for (final e in entries.entries) e.key: e.value.toJson()},
    });
    final bytes = key.bytes;
    Future<String> run() async {
      final packed = GZipEncoder().encodeBytes(utf8.encode(inner));
      final box = await AesGcm.with256bits().encrypt(
        packed,
        secretKey: SecretKey(bytes),
        // Lié à l'identifiant : impossible de faire passer la copie d'un
        // compte pour celle d'un autre.
        aad: utf8.encode('$app:$login'),
      );
      return base64.encode(box.concatenation());
    }

    String data;
    try {
      data = inner.length > 48 * 1024 ? await Isolate.run(run) : await run();
    } catch (_) {
      data = await run();
    }
    return jsonEncode({
      'app': app,
      'version': key.accountSalt == null ? 1 : 2,
      'identifiant': login,
      'chiffre': 'AES-256-GCM / PBKDF2-SHA256',
      'iterations': key.iterations,
      'sel': base64.encode(key.salt),
      'sel_compte': ?key.accountSalt,
      'donnees': data,
    });
  }

  static SyncHeader header(String text) {
    try {
      final j = jsonDecode(text) as Map;
      if (j['app'] != app) throw 'x';
      return SyncHeader(
        '${j['identifiant']}',
        base64.decode('${j['sel']}'),
        (j['iterations'] as num).toInt(),
        '${j['donnees']}',
        j['sel_compte'] as String?,
      );
    } catch (_) {
      throw 'La copie du compte dans le Drive est abîmée';
    }
  }

  static Future<SyncContent> open(SyncHeader h, SyncKey key, String login) async {
    if (h.login != login) throw const WrongPassword();
    final data = h.data;
    final bytes = key.bytes;
    // null : mauvais mot de passe.
    Future<Map<dynamic, dynamic>?> run() async {
      final aes = AesGcm.with256bits();
      final box = SecretBox.fromConcatenation(
        base64.decode(data),
        nonceLength: aes.nonceLength,
        macLength: aes.macAlgorithm.macLength,
      );
      List<int> packed;
      try {
        packed = await aes.decrypt(box, secretKey: SecretKey(bytes), aad: utf8.encode('$app:$login'));
      } on SecretBoxAuthenticationError {
        return null;
      }
      return jsonDecode(utf8.decode(GZipDecoder().decodeBytes(packed))) as Map;
    }

    Map<dynamic, dynamic>? j;
    if (data.length > 64 * 1024) {
      // Grosse copie : déchiffrée à côté, pour que l'appli ne se fige pas.
      try {
        j = await Isolate.run(run);
      } catch (_) {
        j = await run();
      }
    } else {
      j = await run();
    }
    if (j == null) throw const WrongPassword();
    final entries = (j['donnees'] as Map? ?? const {}).cast<String, dynamic>();
    return SyncContent((j['compte'] as Map? ?? const {}).cast<String, dynamic>(), {
      for (final e in entries.entries)
        if (e.value is List && (e.value as List).length >= 2)
          e.key: SyncEntry(
            (e.value as List)[0],
            ((e.value as List)[1] as num).toInt(),
            (e.value as List).length > 2 ? (e.value as List)[2] as String? : null,
          ),
    });
  }
}

/// Une copie de compte (ou une demande) dans le cloud.
class CloudCopy {
  const CloudCopy(this.id, this.name, this.version, [this.modified]);
  final String id;
  final String name;

  /// Change à chaque nouvelle version de la copie.
  final String version;
  final DateTime? modified;

  /// Identifiant Mon Hub du compte (null : autre fichier).
  String? get login {
    final m = RegExp(r'^compte-([a-z0-9._-]+)\.monhub$').firstMatch(name);
    return m?.group(1);
  }
}

/// Là où vivent les copies.
abstract class SyncCloud {
  Future<List<CloudCopy>> list();
  Future<String> read(String id);
  Future<CloudCopy> write(String name, String content, {String? id});
  Future<void> delete(String id);
}

/// Le dossier « Mon Hub - compte synchronisé » du Google Drive de la
/// personne (accès au Drive déjà donné à Mon Hub depuis la v1.37 : rien à
/// reconnecter). Le rangement du Drive ne touche pas aux dossiers.
class DriveFolder implements SyncCloud {
  DriveFolder(this.email);
  final String email;

  static const folderName = 'Mon Hub - compte synchronisé';
  static const _folderMime = 'application/vnd.google-apps.folder';
  static const _files = 'https://www.googleapis.com/drive/v3/files';
  static const _upload = 'https://www.googleapis.com/upload/drive/v3/files';
  static const _fields = 'id,name,version,modifiedTime';

  /// Dossiers trouvés, par compte Google.
  static final _folders = <String, List<String>>{};

  Future<Map<String, String>> _auth() async => {
    'Authorization': 'Bearer ${await GoogleAuth.accessToken(email)}',
  };

  static CloudCopy _copy(Map j) => CloudCopy(
    '${j['id']}',
    '${j['name']}',
    '${j['version'] ?? j['modifiedTime'] ?? ''}',
    DateTime.tryParse('${j['modifiedTime']}'),
  );

  String _error(http.Response r) {
    var m = 'erreur ${r.statusCode}';
    try {
      m = '${((jsonDecode(utf8.decode(r.bodyBytes)) as Map)['error'] as Map)['message']}';
    } catch (_) {}
    if (r.statusCode == 401 || r.statusCode == 403 || m.contains('scope')) {
      return 'Google : reconnecte $email pour autoriser Mon Hub à écrire dans ton Drive '
          '(Réglages → Mes appareils)';
    }
    return 'Google Drive : $m';
  }

  Future<List<Map<dynamic, dynamic>>> _query(String q, String fields) async {
    final r = await http.get(
      Uri.parse(_files).replace(
        queryParameters: {'q': q, 'pageSize': '100', 'fields': 'files($fields)', 'spaces': 'drive'},
      ),
      headers: await _auth(),
    );
    if (r.statusCode >= 400) throw _error(r);
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
    return [for (final f in (j['files'] as List? ?? const [])) f as Map];
  }

  Future<List<String>> _folderIds({bool create = false}) async {
    final known = _folders[email];
    if (known != null && known.isNotEmpty) return known;
    final found = [
      for (final f in await _query(
        "name = '$folderName' and mimeType = '$_folderMime' and trashed = false and 'me' in owners",
        'id',
      ))
        '${f['id']}',
    ];
    if (found.isEmpty && create) {
      final r = await http.post(
        Uri.parse('$_files?fields=id'),
        headers: {...await _auth(), 'Content-Type': 'application/json'},
        body: jsonEncode({
          'name': folderName,
          'mimeType': _folderMime,
          'description': 'Copie chiffrée de ton compte Mon Hub, pour le retrouver sur tes autres appareils. '
              'Illisible sans ton mot de passe Mon Hub. Ne pas supprimer.',
        }),
      );
      if (r.statusCode >= 400) throw _error(r);
      found.add('${(jsonDecode(utf8.decode(r.bodyBytes)) as Map)['id']}');
    }
    if (found.isNotEmpty) _folders[email] = found;
    return found;
  }

  @override
  Future<List<CloudCopy>> list() async {
    final ids = await _folderIds();
    if (ids.isEmpty) return [];
    final inside = ids.map((id) => "'$id' in parents").join(' or ');
    return [for (final f in await _query('($inside) and trashed = false', _fields)) _copy(f)];
  }

  @override
  Future<String> read(String id) async {
    final r = await http.get(Uri.parse('$_files/$id?alt=media'), headers: await _auth());
    if (r.statusCode >= 400) throw _error(r);
    return utf8.decode(r.bodyBytes);
  }

  @override
  Future<CloudCopy> write(String name, String content, {String? id}) async {
    final data = utf8.encode(content);
    http.Response r;
    if (id != null) {
      r = await http.patch(
        Uri.parse('$_upload/$id?uploadType=media&fields=$_fields'),
        headers: {...await _auth(), 'Content-Type': 'application/json'},
        body: data,
      );
    } else {
      final folder = (await _folderIds(create: true)).first;
      const boundary = 'monhub-compte-5c1e';
      final meta = jsonEncode({
        'name': name,
        'parents': [folder],
      });
      final body = BytesBuilder()
        ..add(utf8.encode('--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n$meta\r\n'))
        ..add(utf8.encode('--$boundary\r\nContent-Type: application/json\r\n\r\n'))
        ..add(data)
        ..add(utf8.encode('\r\n--$boundary--'));
      r = await http.post(
        Uri.parse('$_upload?uploadType=multipart&fields=$_fields'),
        headers: {...await _auth(), 'Content-Type': 'multipart/related; boundary=$boundary'},
        body: body.toBytes(),
      );
    }
    if (r.statusCode >= 400) throw _error(r);
    return _copy(jsonDecode(utf8.decode(r.bodyBytes)) as Map);
  }

  @override
  Future<void> delete(String id) async {
    final r = await http.delete(Uri.parse('$_files/$id'), headers: await _auth());
    if (r.statusCode >= 400 && r.statusCode != 404) throw _error(r);
  }
}
