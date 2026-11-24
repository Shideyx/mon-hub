import '../account_sync.dart';
import 'online.dart';

/// La copie chiffrée du compte gardée dans Mon Hub en ligne (table
/// `account_files`, une ligne par fichier, visible seulement par son
/// propriétaire). Même contenu que dans le Google Drive : illisible sans le
/// mot de passe Mon Hub.
class OnlineCloud implements SyncCloud {
  OnlineCloud(this.mail);

  /// « monhub:adresse@mail » (voir [Online.syncMail]).
  final String mail;

  static const _table = 'account_files';

  void _check() {
    final want = mail.substring(Online.syncPrefix.length);
    final have = Online.instance.email?.toLowerCase();
    if (have == null) throw 'Reconnecte ton compte en ligne (Réglages → Compte en ligne).';
    if (have != want) throw 'Ton compte en ligne est $have, pas $want.';
  }

  static CloudCopy _copy(Map j) =>
      CloudCopy('${j['name']}', '${j['name']}', '${j['version'] ?? ''}', DateTime.tryParse('${j['updated_at']}'));

  @override
  Future<List<CloudCopy>> list() async {
    _check();
    try {
      final rows = await Online.instance.db.from(_table).select('name,version,updated_at');
      return [for (final r in rows) _copy(r)];
    } catch (e) {
      throw Online.explain(e);
    }
  }

  @override
  Future<String> read(String id) async {
    _check();
    try {
      final r = await Online.instance.db.from(_table).select('content').eq('name', id).single();
      return '${r['content']}';
    } catch (e) {
      throw Online.explain(e);
    }
  }

  @override
  Future<CloudCopy> write(String name, String content, {String? id}) async {
    _check();
    try {
      final r = await Online.instance.db
          .from(_table)
          .upsert({'user_id': Online.instance.userId, 'name': name, 'content': content}, onConflict: 'user_id,name')
          .select('name,version,updated_at')
          .single();
      return _copy(r);
    } catch (e) {
      throw Online.explain(e);
    }
  }

  @override
  Future<void> delete(String id) async {
    _check();
    try {
      await Online.instance.db.from(_table).delete().eq('name', id);
    } catch (e) {
      throw Online.explain(e);
    }
  }
}
