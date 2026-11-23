import 'dart:math' show Random;

import '../account_sync.dart';
import '../module_store.dart';
import '../session.dart';
import 'online.dart';
import 'spaces.dart';

/// Pas encore de compte Mon Hub relié à cette adresse.
class NoOnlineCopy implements Exception {
  const NoOnlineCopy();
  @override
  String toString() =>
      'Aucun compte Mon Hub n\'est encore relié à cette adresse. Crée ton compte ici (« Nouveau ? Créer un compte ») '
      'en mettant cette adresse : il sera mis en ligne tout de suite.';
}

/// **Même compte partout** : les étapes pour relier un compte Mon Hub à
/// Mon Hub en ligne, et pour le retrouver tel quel sur un autre appareil.
class OnlineAccount {
  OnlineAccount._();

  /// Compte Mon Hub ouvert ici → en ligne : connexion (ou création) avec la
  /// même adresse et le **même mot de passe**, puis copie chiffrée du compte
  /// synchronisée toutes les 3 minutes. Renvoie false s'il faut d'abord
  /// confirmer l'adresse (mail de Supabase).
  static Future<bool> putOnline(String email, String password) async {
    final acc = AppSession.instance.current;
    if (acc == null) throw 'Connecte-toi d\'abord à ton compte Mon Hub.';
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email.trim())) throw 'Tape ton adresse mail.';
    if (!AppSession.instance.checkPassword(password)) {
      throw 'Tape le mot de passe de ton compte Mon Hub (le même servira partout).';
    }
    final name = ModuleStore.prefs.getString('hub.name') ?? acc.name;
    final ok = await Online.instance.signInOrUp(email, password, name: name);
    if (!ok) return false;
    await AccountSync.instance.enable(mail: Online.syncMail(email));
    await ensureProfile();
    return true;
  }

  /// Un @pseudo est donné tout seul la première fois (modifiable ensuite).
  static Future<void> ensureProfile() async {
    final p = await Online.instance.loadProfile();
    if (p != null && p['handle'] != null) return;
    final acc = AppSession.instance.current;
    final name = ModuleStore.prefs.getString('hub.name') ?? acc?.name ?? '';
    var handle = Online.suggestHandle(acc?.login ?? Online.instance.email ?? 'moi');
    for (var i = 0; i < 4; i++) {
      try {
        await Online.instance.saveProfile(name: name, handle: handle);
        return;
      } catch (e) {
        if (!'$e'.contains('déjà pris')) return;
        final base = handle.length > 25 ? handle.substring(0, 25) : handle;
        handle = '$base${Random().nextInt(9000) + 1000}';
      }
    }
  }

  /// Nouvel appareil (page de connexion) : connexion au compte en ligne, puis
  /// le compte Mon Hub arrive avec **tout** (modules, réglages, connexions,
  /// historiques…) et s'ouvre.
  static Future<void> join(String email, String password) async {
    final sync = AccountSync.instance;
    sync.beginJoin();
    try {
      await Online.instance.signIn(email, password);
      final mail = Online.syncMail(email);
      final copies = await AccountSync.copies(mail);
      if (copies.isEmpty) throw const NoOnlineCopy();
      copies.sort((a, b) => (b.modified ?? DateTime(2000)).compareTo(a.modified ?? DateTime(2000)));
      final copy = copies.first;
      if (AppSession.instance.accounts.containsKey(copy.login)) {
        throw 'Le compte « ${copy.login} » est déjà sur cet appareil : connecte-toi avec son identifiant.';
      }
      await sync.join(mail: mail, copy: copy, password: password);
    } on WrongPassword {
      await _abandon();
      throw 'Ce n\'est pas le mot de passe de ce compte Mon Hub.';
    } catch (e) {
      await _abandon();
      if (e is NoOnlineCopy) rethrow;
      throw Online.explain(e);
    }
  }

  static Future<void> _abandon() async {
    await Online.instance.signOut();
    await AccountSync.instance.cancelJoin();
  }

  /// Plus de compte en ligne sur cet appareil (la copie en ligne reste).
  static Future<void> signOutHere() async {
    Spaces.instance.stop();
    if (AccountSync.instance.online) await AccountSync.instance.disable();
    await Online.instance.signOut();
  }
}
