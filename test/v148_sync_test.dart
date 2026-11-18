import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/account_sync.dart';
import 'package:hub/core/google_auth.dart';
import 'package:hub/core/hub_files.dart';
import 'package:hub/core/module_store.dart';
import 'package:hub/core/session.dart';
import 'package:hub/core/vault.dart';
import 'package:hub/ui/account_sync_view.dart';
import 'package:hub/ui/login_page.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Le « Google Drive » des tests : en mémoire.
class _MemoryCloud implements SyncCloud {
  final files = <String, (String, String, int)>{};
  var _next = 0;

  @override
  Future<List<CloudCopy>> list() async => [
    for (final e in files.entries) CloudCopy(e.key, e.value.$1, '${e.value.$3}', DateTime.now()),
  ];

  @override
  Future<String> read(String id) async => files[id]!.$2;

  @override
  Future<CloudCopy> write(String name, String content, {String? id}) async {
    final key = id ?? 'id${_next++}';
    final v = (files[key]?.$3 ?? 0) + 1;
    files[key] = (name, content, v);
    return CloudCopy(key, name, '$v');
  }

  @override
  Future<void> delete(String id) async => files.remove(id);
}

/// Un appareil : ses préférences, son coffre, son dossier, sa clé de coffre.
class _Device {
  _Device(this.dir, this.vaultKey);
  final Directory dir;
  final List<int> vaultKey;
  Map<String, Object> prefs = {};
  Map<String, String> secrets = {};
}

_Device? _current;

/// Passe d'un appareil à l'autre (comme si on changeait de PC).
Future<void> _use(_Device d) async {
  final cur = _current;
  if (cur != null) {
    final p = await SharedPreferences.getInstance();
    cur.prefs = {for (final k in p.getKeys()) k: p.get(k)!};
    cur.secrets = {...await ModuleStore.secure.readAll()};
  }
  SharedPreferences.setMockInitialValues({...d.prefs});
  FlutterSecureStorage.setMockInitialValues({...d.secrets});
  await ModuleStore.init();
  HubFiles.overrideRoot = d.dir.path;
  Vault.overrideKey = d.vaultKey;
  AccountSync.instance.stop();
  AppSession.instance.current = null;
  ModuleStore.profile = '';
  AppSession.instance.restore();
  _current = d;
}

void main() {
  group('Fusion réglage par réglage', () {
    test('le plus récent gagne, les suppressions suivent', () {
      final base = SyncMerge.readStamps(
        SyncMerge.toStamps({
          'p:a': SyncEntry('1', 10),
          'p:b': SyncEntry('x', 10),
          'p:c': SyncEntry('vieux', 10),
        }),
      );
      // Ici : a inchangé, b changé, c supprimé.
      final mine = SyncMerge.stamp({'p:a': '1', 'p:b': 'y'}, base, 100);
      expect(mine['p:a']!.time, 10);
      expect(mine['p:b']!.time, 100);
      expect(mine['p:c']!.value, isNull);
      expect(mine['p:c']!.time, 100);

      // Ailleurs : a changé après, b changé avant, d nouveau.
      final theirs = {
        'p:a': SyncEntry('2', 50),
        'p:b': SyncEntry('z', 40),
        'p:c': SyncEntry('vieux', 10),
        'p:d': SyncEntry('neuf', 60),
      };
      final m = SyncMerge.merge(mine, theirs);
      expect(m['p:a']!.value, '2');
      expect(m['p:b']!.value, 'y');
      expect(m['p:c']!.value, isNull);
      expect(m['p:d']!.value, 'neuf');
      expect(SyncMerge.same(m, {...m}), isTrue);
      expect(SyncMerge.same(m, theirs), isFalse);
    });

    test('les vieilles suppressions sont oubliées', () {
      final now = DateTime(2026, 11, 18).millisecondsSinceEpoch;
      final old = now - const Duration(days: 120).inMilliseconds;
      final m = SyncMerge.prune({
        'p:a': SyncEntry(null, old),
        'p:b': SyncEntry(null, now - 1000),
        'p:c': SyncEntry('ok', old),
      }, now);
      expect(m.keys, unorderedEquals(['p:b', 'p:c']));
    });

    test('presque tout effacé d\'un coup : rien n\'est envoyé', () {
      final base = {for (var i = 0; i < 20; i++) 'p:k$i': (hash: 'h$i', time: 1)};
      final wiped = SyncMerge.stamp({'p:k0': 'v'}, base, 5);
      expect(() => SyncMerge.checkNotWiped(wiped, base), throwsA(isA<String>()));
      final some = SyncMerge.stamp({for (var i = 0; i < 15; i++) 'p:k$i': 'v'}, base, 5);
      SyncMerge.checkNotWiped(some, base);
    });

    test('ce qui est propre au PC reste sur le PC', () {
      expect(AccountSync.syncedPref('mod.ecoledirecte.user'), isTrue);
      expect(AccountSync.syncedPref('hub.order'), isTrue);
      expect(AccountSync.syncedPref('hub.detached'), isFalse);
      expect(AccountSync.syncedPref('hub.detached.rect.musique'), isFalse);
      expect(AccountSync.syncedPref('shortcut.target'), isFalse);
      expect(AccountSync.syncedPref('app.accounts'), isFalse);
      expect(AccountSync.syncedPref('sync.email'), isFalse);
      expect(AccountSync.syncedSecret('vault.key'), isFalse);
      expect(AccountSync.syncedSecret('sync.key'), isFalse);
      expect(AccountSync.syncedSecret('mod.google.refresh.a@b.c'), isTrue);
      expect(AccountSync.syncedFile('carnet.json'), isTrue);
      expect(AccountSync.syncedFile('rangement-123.json'), isFalse);
      expect(AccountSync.syncedFile('sync-base.json'), isFalse);
      expect(AccountSync.syncedFile('../../evil.json'), isFalse);
      expect(AccountSync.syncedFile('carnet.json.tmp'), isFalse);
    });

    test('nom des copies', () {
      expect(const CloudCopy('1', 'compte-erik.monhub', '3').login, 'erik');
      expect(const CloudCopy('1', 'autre.txt', '3').login, isNull);
      expect(AccountSync.fileName('erik'), 'compte-erik.monhub');
    });

    test('« il y a… »', () {
      final now = DateTime(2026, 11, 18, 12);
      expect(syncAgo(now.subtract(const Duration(seconds: 20)), now: now), 'à l\'instant');
      expect(syncAgo(now.subtract(const Duration(minutes: 3)), now: now), 'il y a 3 min');
      expect(syncAgo(now.subtract(const Duration(hours: 2)), now: now), 'il y a 2 h');
      expect(syncAgo(DateTime(2026, 11, 2), now: now), 'le 02/11');
    });
  });

  group('Mon compte sur plusieurs appareils', () {
    late Directory tmp;
    late _MemoryCloud cloud;
    const mail = 'erik@gmail.com';

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('monhub-sync');
      cloud = _MemoryCloud();
      AccountSync.cloudFor = (_) => cloud;
      SyncKey.defaultIterations = 1000;
      _current = null;
    });

    tearDown(() async {
      AccountSync.instance.stop();
      AccountSync.cloudFor = DriveFolder.new;
      SyncKey.defaultIterations = 210000;
      HubFiles.overrideRoot = null;
      Vault.overrideKey = null;
      AppSession.instance.current = null;
      ModuleStore.profile = '';
      _current = null;
      await tmp.delete(recursive: true);
    });

    _Device device(String name, int key) =>
        _Device(Directory('${tmp.path}/$name')..createSync(), List.filled(32, key));

    test('activé sur le PC, retrouvé sur un autre sans export, puis tout suit', () async {
      final pc = device('pc', 1);
      final laptop = device('portable', 2);

      // ---- PC : le compte existe, avec des réglages, une connexion, un fichier.
      await _use(pc);
      await AppSession.instance.register('erik', 'Erik', 'motdepasse1');
      await ModuleStore.prefs.setStringList('hub.order', ['musique', 'agenda']);
      await ModuleStore.prefs.setString('mod.ecoledirecte.user', 'erik.m');
      await ModuleStore.prefs.setInt('notif.interval', 5);
      await ModuleStore.prefs.setDouble('mod.claude.clicky.speed', 1.5);
      await ModuleStore.prefs.setString('hub.detached', '["musique"]');
      await ModuleStore.writeSecretRaw('mod.ecoledirecte.password', 'secret-ed');
      final carnet = (await HubFiles.file('carnet.json'))!;
      await carnet.writeAsString(await Vault.seal('{"facts":["aime le foot"]}'));

      // Pas besoin de retaper le mot de passe : la clé vient de son empreinte.
      await AccountSync.instance.enable(mail: mail);
      expect(AccountSync.instance.error, isNull);
      expect(AccountSync.instance.enabled, isTrue);
      expect(cloud.files, hasLength(1));
      // Chiffré : rien de lisible dans le Drive.
      final stored = cloud.files.values.single.$2;
      for (final secret in ['secret-ed', 'erik.m', 'foot', 'musique']) {
        expect(stored, isNot(contains(secret)));
      }

      // Rien n'a changé : pas de nouvel envoi.
      await AccountSync.instance.syncNow();
      expect(cloud.files.values.single.$3, 1);

      // ---- Portable : aucun compte, on le retrouve.
      await _use(laptop);
      expect(AppSession.instance.current, isNull);
      final copies = await AccountSync.copies(mail);
      expect(copies.single.login, 'erik');

      AccountSync.instance.beginJoin();
      // La connexion Google faite pour le retrouver se range dans le compte.
      await ModuleStore.writeSecretRaw('mod.google.refresh.$mail', 'jeton-portable');
      await expectLater(
        AccountSync.instance.join(mail: mail, copy: copies.single, password: 'mauvais'),
        throwsA(isA<WrongPassword>()),
      );
      await AccountSync.instance.join(mail: mail, copy: copies.single, password: 'motdepasse1');

      expect(AppSession.instance.current?.login, 'erik');
      expect(AppSession.instance.current?.name, 'Erik');
      expect(ModuleStore.prefs.getStringList('hub.order'), ['musique', 'agenda']);
      expect(ModuleStore.prefs.getString('mod.ecoledirecte.user'), 'erik.m');
      expect(ModuleStore.prefs.getInt('notif.interval'), 5);
      expect(ModuleStore.prefs.get('mod.claude.clicky.speed'), 1.5);
      expect(ModuleStore.prefs.getString('hub.detached'), isNull, reason: 'propre au PC');
      final secrets = await ModuleStore.readAllSecrets();
      expect(secrets['mod.ecoledirecte.password'], 'secret-ed');
      expect(secrets['mod.google.refresh.$mail'], 'jeton-portable');
      final there = (await HubFiles.file('carnet.json'))!;
      expect(await Vault.open(await there.readAsString()), contains('foot'));
      // Rechiffré avec la clé de coffre du portable (pas celle du PC).
      Vault.overrideKey = pc.vaultKey;
      await expectLater(Vault.open(await there.readAsString()), throwsA(anything));
      Vault.overrideKey = laptop.vaultKey;

      // Le même identifiant et le même mot de passe marchent ici.
      await AppSession.instance.signOut();
      await AppSession.instance.signIn('erik', 'motdepasse1');
      expect(AppSession.instance.current?.login, 'erik');

      // Ce qui ne venait que du portable part dans le Drive.
      await AccountSync.instance.syncNow();
      expect(AccountSync.instance.error, isNull);

      // ---- Des deux côtés, chacun change autre chose : tout se rejoint.
      await ModuleStore.prefs.setString('mod.ecoledirecte.user', 'erik.nouveau');
      await AccountSync.instance.syncNow();
      expect(AccountSync.instance.error, isNull);

      await _use(pc);
      expect(AppSession.instance.current?.login, 'erik');
      await ModuleStore.prefs.setInt('notif.interval', 10);
      await ModuleStore.prefs.remove('mod.claude.clicky.speed');
      await AccountSync.instance.syncNow();
      expect(AccountSync.instance.error, isNull);
      expect(ModuleStore.prefs.getString('mod.ecoledirecte.user'), 'erik.nouveau');
      expect(ModuleStore.prefs.getInt('notif.interval'), 10);
      expect(ModuleStore.prefs.getString('hub.detached'), '["musique"]');

      await _use(laptop);
      await AccountSync.instance.syncNow();
      expect(ModuleStore.prefs.getInt('notif.interval'), 10);
      expect(ModuleStore.prefs.get('mod.claude.clicky.speed'), isNull, reason: 'supprimé sur le PC');
      expect(ModuleStore.prefs.getString('mod.ecoledirecte.user'), 'erik.nouveau');
    });

    test('un gros historique passe aussi (et n\'est pas renvoyé s\'il n\'a pas bougé)', () async {
      final rnd = Random(1);
      final big = String.fromCharCodes(List.generate(300000, (_) => 97 + rnd.nextInt(26)));
      await _use(device('pc', 1));
      await AppSession.instance.register('erik', '', 'motdepasse1');
      final f = (await HubFiles.file('clicky-history.json'))!;
      await f.writeAsString(await Vault.seal(jsonEncode([big])));
      await AccountSync.instance.enable(mail: mail);
      expect(AccountSync.instance.error, isNull);
      expect(cloud.files.values.single.$2.length, greaterThan(64 * 1024));
      await AccountSync.instance.syncNow();
      expect(cloud.files.values.single.$3, 1);

      await _use(device('portable', 2));
      final copy = (await AccountSync.copies(mail)).single;
      await AccountSync.instance.join(mail: mail, copy: copy, password: 'motdepasse1');
      final there = (await HubFiles.file('clicky-history.json'))!;
      expect(jsonDecode(await Vault.open(await there.readAsString())), [big]);
    });

    test('PC principal hors de portée : le nouvel appareil demande, le PC principal envoie tout seul', () async {
      final pc = device('pc', 1);
      final laptop = device('portable', 2);

      // PC principal : compte ouvert, Google connecté, synchro jamais activée.
      await _use(pc);
      await AppSession.instance.register('erik', 'Erik', 'motdepasse1');
      await ModuleStore.prefs.setString('mod.ecoledirecte.user', 'erik.m');
      await ModuleStore.prefs.setString('mod.google.accounts', jsonEncode([mail]));
      await ModuleStore.prefs.setString('mod.google.scopes.$mail', jsonEncode('openid ${GoogleAuth.driveScope}'));
      String? notice;
      AccountSync.instance.onNotice = (t, _) => notice = t;
      // Personne n'a rien demandé : il ne se passe rien.
      await AccountSync.instance.answerRequests();
      expect(cloud.files, isEmpty);
      expect(AccountSync.instance.enabled, isFalse);

      // Nouvel appareil : rien dans le Drive, il dépose une demande.
      await _use(laptop);
      AccountSync.instance.beginJoin();
      expect(await AccountSync.copies(mail), isEmpty);
      await expectLater(AccountSync.requestCopy(mail, ''), throwsA(isA<String>()));
      await AccountSync.requestCopy(mail, ' Erik ');
      expect(cloud.files.values.single.$1, 'demande-compte-erik.json');
      await AccountSync.instance.cancelJoin();

      // PC principal (Mon Hub ouvert, personne devant) : il répond.
      await _use(pc);
      await AccountSync.instance.answerRequests();
      expect(AccountSync.instance.error, isNull);
      expect(AccountSync.instance.enabled, isTrue);
      expect(notice, isNotNull);
      expect(cloud.files.values.map((f) => f.$1), ['compte-erik.monhub'], reason: 'demande effacée');
      AccountSync.instance.onNotice = null;

      // Nouvel appareil : le compte est là, il suffit du mot de passe.
      await _use(laptop);
      final copy = (await AccountSync.copies(mail)).single;
      await expectLater(
        AccountSync.instance.join(mail: mail, copy: copy, password: 'mauvais'),
        throwsA(isA<WrongPassword>()),
      );
      await AccountSync.instance.join(mail: mail, copy: copy, password: 'motdepasse1');
      expect(AppSession.instance.current?.login, 'erik');
      expect(ModuleStore.prefs.getString('mod.ecoledirecte.user'), 'erik.m');

      // Et ensuite tout suit, dans les deux sens.
      await ModuleStore.prefs.setString('mod.ecoledirecte.user', 'erik.portable');
      await AccountSync.instance.syncNow();
      await _use(pc);
      await AccountSync.instance.syncNow();
      expect(ModuleStore.prefs.getString('mod.ecoledirecte.user'), 'erik.portable');
    });

    Future<void> google() async {
      await ModuleStore.prefs.setString('mod.google.accounts', jsonEncode([mail]));
      await ModuleStore.prefs.setString('mod.google.scopes.$mail', jsonEncode('openid ${GoogleAuth.driveScope}'));
    }

    test('PC principal éteint : compte recréé ici, ses données arrivent quand il revient', () async {
      final pc = device('pc', 1);
      final laptop = device('portable', 2);

      // PC principal : l'ancien compte, avec ses données.
      await _use(pc);
      await AppSession.instance.register('erik', 'Erik', 'motdepasse1');
      await google();
      await ModuleStore.prefs.setString('mod.ecoledirecte.user', 'erik.m');
      await ModuleStore.prefs.setStringList('hub.order', ['musique', 'agenda']);
      final carnet = (await HubFiles.file('carnet.json'))!;
      await carnet.writeAsString(await Vault.seal('{"facts":["aime le foot"]}'));

      // Il est éteint : on recrée le compte ici (même identifiant, même mot de passe).
      await _use(laptop);
      await AppSession.instance.register('erik', 'Erik', 'motdepasse1');
      await google();
      await ModuleStore.prefs.setStringList('hub.order', ['agenda']);
      await ModuleStore.prefs.setString('mod.carnet.note', 'fait sur le portable');
      await AccountSync.instance.askMainPc(mail);
      expect(AccountSync.instance.askedIn, mail);
      expect(AccountSync.instance.arrived, isNull);
      expect(cloud.files.values.single.$1, 'demande-compte-erik.json');

      // Le PC principal est rallumé, Mon Hub s'ouvre : il répond tout seul.
      await _use(pc);
      await AccountSync.instance.answerRequests();
      expect(AccountSync.instance.enabled, isTrue);
      expect(cloud.files.values.map((f) => f.$1), ['compte-erik.monhub']);

      // Ici : les données sont arrivées, il ne manque que le mot de passe.
      await _use(laptop);
      expect(AccountSync.instance.askedIn, mail);
      await AccountSync.instance.checkArrival();
      expect(AccountSync.instance.arrived, isNotNull);
      await expectLater(AccountSync.instance.mergeFrom('mauvais'), throwsA('Mot de passe incorrect'));
      await AccountSync.instance.mergeFrom('motdepasse1');
      expect(AccountSync.instance.error, isNull);
      expect(AccountSync.instance.askedIn, isNull);
      expect(AccountSync.instance.enabled, isTrue);
      expect(ModuleStore.prefs.getString('mod.ecoledirecte.user'), 'erik.m');
      expect(ModuleStore.prefs.getStringList('hub.order'), ['musique', 'agenda'], reason: 'le PC principal gagne');
      expect(ModuleStore.prefs.getString('mod.carnet.note'), 'fait sur le portable', reason: 'rien de perdu ici');
      final here = (await HubFiles.file('carnet.json'))!;
      expect(await Vault.open(await here.readAsString()), contains('foot'));

      // Et le PC principal reçoit ce qui a été fait sur le portable.
      await _use(pc);
      await AccountSync.instance.syncNow();
      expect(AccountSync.instance.error, isNull);
      expect(ModuleStore.prefs.getString('mod.carnet.note'), 'fait sur le portable');
      expect(ModuleStore.prefs.getString('mod.ecoledirecte.user'), 'erik.m');
    });

    test('compte recréé ici avec la synchro déjà active : le PC principal reprend la main', () async {
      final pc = device('pc', 1);
      final laptop = device('portable', 2);
      await _use(pc);
      await AppSession.instance.register('erik', 'Erik', 'motdepasse1');
      await google();
      await ModuleStore.prefs.setString('mod.ecoledirecte.user', 'erik.m');

      await _use(laptop);
      await AppSession.instance.register('erik', 'Erik', 'motdepasse1');
      await google();
      await ModuleStore.prefs.setString('mod.carnet.note', 'portable');
      await AccountSync.instance.enable(mail: mail);
      await AccountSync.instance.askMainPc(mail);
      expect(AccountSync.instance.arrived, isNull);

      // Le PC principal ne peut pas ouvrir la copie du portable : il la remplace.
      await _use(pc);
      await AccountSync.instance.answerRequests();
      expect(AccountSync.instance.error, isNull);
      expect(AccountSync.instance.enabled, isTrue);

      // Le portable : mot de passe une fois, puis tout est fusionné.
      await _use(laptop);
      await AccountSync.instance.checkArrival();
      expect(AccountSync.instance.needsPassword, isTrue);
      await AccountSync.instance.unlock('motdepasse1');
      expect(AccountSync.instance.needsPassword, isFalse);
      expect(AccountSync.instance.askedIn, isNull);
      expect(ModuleStore.prefs.getString('mod.ecoledirecte.user'), 'erik.m');
      expect(ModuleStore.prefs.getString('mod.carnet.note'), 'portable');

      await _use(pc);
      await AccountSync.instance.syncNow();
      expect(ModuleStore.prefs.getString('mod.carnet.note'), 'portable');
    });

    test('ancienne copie (v1.48, clé du mot de passe) : toujours lisible', () async {
      await _use(device('pc', 1));
      await AppSession.instance.register('erik', '', 'motdepasse1');
      final acc = AppSession.instance.current!;
      final old = await SyncKey.derive('motdepasse1');
      final text = await SyncBox.seal(
        login: 'erik',
        account: acc,
        key: old,
        entries: {'p:hub.name': SyncEntry('Erik', 1)},
      );
      final h = SyncBox.header(text);
      expect(h.accountSalt, isNull);
      final again = await SyncKey.fromPassword(h, 'motdepasse1');
      expect((await SyncBox.open(h, again, 'erik')).entries['p:hub.name']!.value, 'Erik');
      // Nouvelle copie : la clé vient de l'empreinte, la même sur tous les appareils.
      final now = await SyncKey.forAccount(acc);
      final h2 = SyncBox.header(await SyncBox.seal(login: 'erik', account: acc, key: now, entries: {}));
      expect(h2.accountSalt, acc.salt);
      final typed = await SyncKey.fromPassword(h2, 'motdepasse1');
      expect(typed.bytes, now.bytes);
    });

    test('un nouveau compte ne peut pas se faire passer pour un autre', () async {
      final pc = device('pc', 1);
      await _use(pc);
      await AppSession.instance.register('erik', '', 'motdepasse1');
      await AccountSync.instance.enable(mail: mail);
      final text = cloud.files.values.single.$2;
      final h = SyncBox.header(text);
      final key = await SyncKey.fromPassword(h, 'motdepasse1');
      expect((await SyncBox.open(h, key, 'erik')).account['nom'], 'erik');
      // Même contenu présenté comme le compte « lea » : refusé.
      await expectLater(
        SyncBox.open(SyncBox.header(text.replaceFirst('"identifiant":"erik"', '"identifiant":"lea"')), key, 'lea'),
        throwsA(isA<WrongPassword>()),
      );
    });

    test('retour sur la page de connexion : rien ne reste', () async {
      final laptop = device('portable', 2);
      await _use(laptop);
      AccountSync.instance.beginJoin();
      final ns = ModuleStore.profile;
      expect(ns, startsWith('p.'));
      await ModuleStore.prefs.setString('mod.google.accounts', '["$mail"]');
      await ModuleStore.writeSecretRaw('mod.google.refresh.$mail', 'jeton');
      await AccountSync.instance.cancelJoin();
      expect(ModuleStore.profile, '');
      final p = await SharedPreferences.getInstance();
      expect(p.getKeys().where((k) => k.startsWith(ns)), isEmpty);
      expect((await ModuleStore.secure.readAll()).keys.where((k) => k.startsWith(ns)), isEmpty);
    });

    test('arrêter et supprimer la copie', () async {
      await _use(device('pc', 1));
      await AppSession.instance.register('erik', '', 'motdepasse1');
      await AccountSync.instance.enable(mail: mail);
      expect(cloud.files, hasLength(1));
      await AccountSync.instance.disable(deleteCopy: true);
      expect(cloud.files, isEmpty);
      expect(AccountSync.instance.enabled, isFalse);
      expect((await ModuleStore.readAllSecrets()).containsKey('sync.key'), isFalse);
    });

    testWidgets('page de connexion : « Retrouver mon compte »', (tester) async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      await ModuleStore.init();
      await tester.pumpWidget(const MaterialApp(home: LoginPage()));
      final join = find.text('Retrouver mon compte d\'un autre appareil');
      await tester.ensureVisible(join);
      await tester.pumpAndSettle();
      await tester.tap(join);
      await tester.pump();
      expect(find.text('Se connecter avec Google'), findsOneWidget);
      expect(ModuleStore.profile, startsWith('p.'));
      await tester.ensureVisible(find.text('Retour'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Retour'));
      await tester.pumpAndSettle();
      expect(find.text('Créer mon compte'), findsOneWidget);
      expect(ModuleStore.profile, '');
    });
  });
}
