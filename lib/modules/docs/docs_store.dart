import 'package:flutter/foundation.dart';

import '../../core/hub_files.dart';
import 'doc_format.dart';

/// Un document (ses infos ; le contenu est dans son propre fichier).
class HubDoc {
  HubDoc({
    required this.id,
    required this.title,
    required this.created,
    required this.updated,
    this.preview = '',
    this.words = 0,
    this.googleId,
  });

  final String id;
  String title;
  final DateTime created;
  DateTime updated;

  /// Le début du texte (aperçu de la page).
  String preview;
  int words;

  /// Le Google Doc lié (ouvert depuis le Drive, ou envoyé sur le Drive).
  String? googleId;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'created': created.millisecondsSinceEpoch,
    'updated': updated.millisecondsSinceEpoch,
    'preview': preview,
    'words': words,
    'googleId': ?googleId,
  };

  factory HubDoc.fromJson(Map j) => HubDoc(
    id: '${j['id']}',
    title: '${j['title'] ?? 'Sans titre'}',
    created: DateTime.fromMillisecondsSinceEpoch((j['created'] as num?)?.toInt() ?? 0),
    updated: DateTime.fromMillisecondsSinceEpoch((j['updated'] as num?)?.toInt() ?? 0),
    preview: '${j['preview'] ?? ''}',
    words: (j['words'] as num?)?.toInt() ?? 0,
    googleId: j['googleId'] as String?,
  );
}

/// Tes documents, chiffrés sur l'appareil (rien n'est envoyé ailleurs, sauf
/// si tu l'envoies toi-même sur Google Docs).
class DocStore extends ChangeNotifier {
  DocStore._();
  static final instance = DocStore._();

  final _index = JsonFile<List<HubDoc>>(
    'documents.json',
    empty: () => [],
    decode: (j) => [
      for (final e in (j is List ? j : const []))
        if (e is Map) HubDoc.fromJson(e),
    ],
    encode: (v) => [for (final d in v) d.toJson()],
  );

  final _files = <String, JsonFile<List<dynamic>>>{};

  JsonFile<List<dynamic>> _file(String id) => _files[id] ??= JsonFile<List<dynamic>>(
    'document-$id.json',
    empty: () => [
      {'insert': '\n'},
    ],
    decode: (j) => j is List && j.isNotEmpty
        ? j
        : [
            {'insert': '\n'},
          ],
    encode: (v) => v,
  );

  /// Les documents, du plus récent au plus ancien.
  List<HubDoc> get docs => [..._index.value]..sort((a, b) => b.updated.compareTo(a.updated));

  Future<List<HubDoc>> load() async {
    await _index.load();
    notifyListeners();
    return docs;
  }

  HubDoc? byId(String id) => _index.value.where((d) => d.id == id).firstOrNull;

  /// Retrouve un document par son titre (pour Clicky : « mon exposé »).
  HubDoc? find(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return null;
    return byId(query) ??
        docs.where((d) => d.title.toLowerCase() == q).firstOrNull ??
        docs.where((d) => d.title.toLowerCase().contains(q)).firstOrNull;
  }

  Future<List<dynamic>> read(String id) => _file(id).load();

  Future<HubDoc> create({String title = 'Sans titre', List<dynamic>? ops, String? googleId}) async {
    final now = DateTime.now();
    final d = HubDoc(id: '${now.microsecondsSinceEpoch}', title: title, created: now, updated: now, googleId: googleId);
    await write(d.id, ops ?? [{'insert': '\n'}], doc: d);
    return d;
  }

  /// Enregistre le contenu (et met à jour l'aperçu, le nombre de mots).
  Future<void> write(String id, List<dynamic> ops, {String? title, HubDoc? doc}) async {
    await _file(id).save(ops);
    await _index.update((l) {
      final d = l.where((x) => x.id == id).firstOrNull ?? doc;
      if (d == null) return l;
      if (!l.contains(d)) l.add(d);
      final text = DocFormat.plain(ops);
      d
        ..title = (title ?? d.title).trim().isEmpty ? 'Sans titre' : (title ?? d.title).trim()
        ..updated = DateTime.now()
        ..preview = text.length > 400 ? text.substring(0, 400) : text
        ..words = DocFormat.words(ops);
      return l;
    });
    notifyListeners();
  }

  Future<void> rename(String id, String title) async {
    await _index.update((l) {
      final d = l.where((x) => x.id == id).firstOrNull;
      if (d != null && title.trim().isNotEmpty) d.title = title.trim();
      return l;
    });
    notifyListeners();
  }

  Future<void> linkGoogle(String id, String? googleId) async {
    await _index.update((l) {
      final d = l.where((x) => x.id == id).firstOrNull;
      if (d != null) d.googleId = googleId;
      return l;
    });
    notifyListeners();
  }

  Future<HubDoc> duplicate(String id) async {
    final src = byId(id);
    return create(title: '${src?.title ?? 'Document'} (copie)', ops: [...await read(id)]);
  }

  Future<void> delete(String id) async {
    await _index.update((l) => l..removeWhere((d) => d.id == id));
    try {
      final f = await HubFiles.file('document-$id.json');
      if (f != null && await f.exists()) await f.delete();
    } catch (_) {}
    _files.remove(id);
    notifyListeners();
  }
}
