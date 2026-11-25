import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'powershell.dart';

/// Un résultat de la recherche partout.
class SearchHit {
  const SearchHit({
    required this.source,
    required this.title,
    this.detail = '',
    this.date,
    this.link,
    this.path,
    this.moduleId,
    this.score = 1,
  });

  /// D'où il vient (« PC », « Drive », « Mails »…).
  final String source;
  final String title;
  final String detail;
  final DateTime? date;

  /// Un lien web à ouvrir (Drive, Google Docs).
  final String? link;

  /// Un fichier du PC.
  final String? path;

  /// Le module à ouvrir (mails, Discord, École Directe…).
  final String? moduleId;
  final double score;

  Map<String, dynamic> toJson() => {
    'ou': source,
    'titre': title,
    if (detail.isNotEmpty) 'detail': detail,
    if (date != null) 'date': date!.toIso8601String(),
    'lien': ?link,
    'fichier': ?path,
  };
}

/// **Recherche partout** (Ctrl + Espace dans Mon Hub, Ctrl + Alt + Espace
/// partout) : un mot, et Mon Hub cherche dans les fichiers du PC (l'index de
/// Windows), le Drive, Google Docs, les mails, Discord, École Directe, le
/// Carnet, le presse-papier, les comptes rendus de cours, les révisions et
/// les livres. **Sans IA**, et rien ne quitte le PC (sauf les recherches
/// Drive/Docs, faites dans **ton** compte Google).
class EverywhereSearch {
  EverywhereSearch._();

  static String norm(String s) {
    const from = 'àâäáãåçéèêëíìîïñóòôöõúùûüýÿœæ';
    const to = 'aaaaaaceeeeiiiinooooouuuuyyoa';
    final b = StringBuffer();
    for (final ch in s.toLowerCase().split('')) {
      final i = from.indexOf(ch);
      b.write(i < 0 ? ch : to[i]);
    }
    return b.toString().replaceAll(RegExp(r"[’'`]"), ' ');
  }

  static const _stop = {
    'le',
    'la',
    'les',
    'de',
    'du',
    'des',
    'un',
    'une',
    'et',
    'ou',
    'mon',
    'ma',
    'mes',
    'ton',
    'ta',
    'tes',
    'sur',
    'pour',
    'a',
    'au',
    'aux',
    'en',
    'dans',
    'avec',
    'l',
    'd',
    'j',
    'qu',
    'que',
    'qui',
    'ce',
    'cet',
    'cette',
  };

  /// Les mots cherchés (sans les petits mots).
  static List<String> words(String query) {
    final all = norm(query).split(RegExp(r'[^a-z0-9+#@.-]+')).where((w) => w.isNotEmpty).toList();
    final kept = [
      for (final w in all)
        if (!_stop.contains(w)) w,
    ];
    return kept.isEmpty ? all : kept;
  }

  /// La note d'un texte : 0 s'il manque un mot ; plus haut si les mots sont
  /// dans le titre.
  static double score(List<String> words, String title, String detail) {
    if (words.isEmpty) return 0;
    final t = norm(title), d = norm(detail);
    var s = 0.0;
    for (final w in words) {
      if (t.contains(w)) {
        s += RegExp('(?:^|[^a-z0-9])${RegExp.escape(w)}').hasMatch(t) ? 3 : 2;
      } else if (d.contains(w)) {
        s += 1;
      } else {
        return 0;
      }
    }
    return s / words.length;
  }

  static DateTime? _date(Object? v) => switch (v) {
    DateTime() => v,
    num() => DateTime.fromMillisecondsSinceEpoch(v.toInt()),
    _ => DateTime.tryParse('${v ?? ''}'),
  };

  static List<Map> _maps(Object? v) => [
    if (v is List)
      for (final x in v)
        if (x is Map) x,
  ];

  static String _short(Object? s, [int max = 140]) {
    final t = '${s ?? ''}'.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length > max ? '${t.substring(0, max)}…' : t;
  }

  /// Un extrait autour du premier mot trouvé.
  static String around(String text, List<String> words, [int max = 140]) {
    final t = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.length <= max) return t;
    final n = norm(t);
    var at = -1;
    for (final w in words) {
      final i = n.indexOf(w);
      if (i >= 0 && (at < 0 || i < at)) at = i;
    }
    if (at < 0) return _short(t, max);
    final start = (at - 40).clamp(0, t.length);
    final end = (start + max).clamp(0, t.length);
    return '${start > 0 ? '…' : ''}${t.substring(start, end)}${end < t.length ? '…' : ''}';
  }

  /// Transforme ce que renvoie un outil de lecture en résultats.
  static List<SearchHit> fromTool(String tool, Object? r, List<String> w) {
    final out = <SearchHit>[];
    void add(
      String source,
      String title,
      String detail, {
      Object? date,
      String? link,
      String? module,
      bool trusted = false,
    }) {
      final s = score(w, title, detail);
      // Les outils qui ont déjà cherché eux-mêmes (Drive, Docs) : gardés.
      if (s <= 0 && !trusted) return;
      out.add(
        SearchHit(
          source: source,
          title: title.trim().isEmpty ? '(sans titre)' : _short(title, 90),
          detail: around(detail, w),
          date: _date(date),
          link: link,
          moduleId: module,
          score: s <= 0 ? 0.5 : s,
        ),
      );
    }

    switch (tool) {
      case 'drive_chercher':
        for (final f in _maps(r)) {
          add(
            'Drive',
            '${f['nom'] ?? ''}',
            '${f['type'] ?? ''}'.split('.').last,
            date: f['modifie'],
            link: f['lien'] as String?,
            trusted: true,
          );
        }
      case 'doc_lister':
        for (final f in _maps(r)) {
          final id = '${f['id'] ?? ''}';
          add(
            'Google Docs',
            '${f['titre'] ?? ''}',
            '',
            date: f['modifie'],
            link: id.isEmpty ? null : 'https://docs.google.com/document/d/$id/edit',
            trusted: true,
          );
        }
      case 'mails_lister':
        for (final m in _maps(r)) {
          add('Mails', '${m['objet'] ?? ''}', '${m['de'] ?? ''}', date: m['date'], module: 'mail');
        }
      case 'discord_conversations':
        for (final d in _maps(r)) {
          add('Discord', '${d['nom'] ?? ''}', '${d['dernier'] ?? ''}', date: d['date'], module: 'discord');
        }
      case 'ecole_messages':
        for (final m in _maps(r)) {
          add('École Directe', '${m['objet'] ?? ''}', '${m['de'] ?? ''}', date: m['date'], module: 'ecoledirecte');
        }
      case 'ecole_devoirs':
        for (final h in _maps(r)) {
          add(
            'Devoirs',
            '${h['matiere'] ?? ''}',
            '${h['contenu'] ?? ''} ${(h['fichiers_joints'] as List?)?.join(' ') ?? ''} ${h['fait_en_classe'] ?? ''}',
            date: h['pour_le'],
            module: 'ecoledirecte',
          );
        }
      case 'carnet_taches_notes':
        if (r is Map) {
          for (final (k, label) in const [('a_faire', 'Tâche'), ('notes', 'Note'), ('fait', 'Tâche faite')]) {
            for (final x in (r[k] is List ? r[k] as List : const [])) {
              add('Carnet', label, '$x', module: 'carnet');
            }
          }
        }
      case 'carnet_idees':
        for (final i in _maps(r)) {
          add('Carnet', 'Idée', '${i['texte'] ?? ''}', date: i['le'], module: 'carnet');
        }
      case 'carnet_presse_papier':
        for (final c in _maps(r)) {
          add('Presse-papier', 'Copié', '${c['texte'] ?? ''}', date: c['copie_le'], module: 'carnet');
        }
      case 'cours_comptes_rendus':
        for (final c in _maps(r)) {
          add('Cours écoutés', '${c['matiere'] ?? ''}', '${c['compte_rendu'] ?? ''}', date: c['date']);
        }
      case 'revision_paquets':
        if (r is Map) {
          for (final d in _maps(r['paquets'])) {
            add('Révisions', '${d['nom'] ?? ''}', '${d['cartes'] ?? 0} cartes', module: 'revisions');
          }
          for (final t in _maps(r['controles'])) {
            add(
              'Révisions',
              'Contrôle de ${t['matiere'] ?? ''}',
              '${t['contenu'] ?? ''}',
              date: t['date'],
              module: 'revisions',
            );
          }
        }
      case 'livres_lister':
        for (final b in _maps(r)) {
          add('Livres', '${b['titre'] ?? ''}', '${b['auteur'] ?? ''} ${b['a_retenir'] ?? ''}', module: 'books');
        }
    }
    return out;
  }

  /// Les outils lus, avec leurs paramètres.
  static Map<String, Map<String, dynamic>> toolsFor(String query) => {
    'drive_chercher': {'nom': query},
    'doc_lister': {'recherche': query},
    'mails_lister': {'nombre': 60},
    'discord_conversations': const {},
    'ecole_messages': const {},
    'ecole_devoirs': const {},
    'carnet_taches_notes': const {'action': 'liste'},
    'carnet_idees': const {'action': 'liste'},
    'carnet_presse_papier': const {'action': 'recent'},
    'cours_comptes_rendus': const {},
    'revision_paquets': const {},
    'livres_lister': const {},
  };

  /// Fichiers du PC : l'index de recherche de Windows (noms et contenu).
  static const pcScript = r'''
param($q)
$ErrorActionPreference = 'Stop'
$words = @($q -split '\s+' | Where-Object { $_ })
$cond = ($words | ForEach-Object { "(System.ItemNameDisplay LIKE '%$_%' OR CONTAINS(*, '""$_*""'))" }) -join ' AND '
$root = $env:USERPROFILE -replace '\\', '/'
$sql = "SELECT TOP 30 System.ItemPathDisplay, System.ItemNameDisplay, System.DateModified FROM SystemIndex WHERE SCOPE='file:$root' AND System.ItemType <> 'Directory' AND System.ItemPathDisplay NOT LIKE '%\AppData\%' AND $cond ORDER BY System.DateModified DESC"
$c = New-Object -ComObject ADODB.Connection
$c.Open("Provider=Search.CollatorDSO;Extended Properties='Application=Windows';")
$rs = New-Object -ComObject ADODB.Recordset
$rs.Open($sql, $c)
$out = @()
while (-not $rs.EOF) {
  $d = $rs.Fields.Item('System.DateModified').Value
  $out += @{ chemin = "$($rs.Fields.Item('System.ItemPathDisplay').Value)"; nom = "$($rs.Fields.Item('System.ItemNameDisplay').Value)"; modifie = $(if ($d) { ([datetime]$d).ToString('o') } else { '' }) }
  $rs.MoveNext()
}
$rs.Close(); $c.Close()
ConvertTo-Json -InputObject @($out) -Compress
''';

  /// Les mots passés à l'index de Windows (sans guillemets ni apostrophes :
  /// rien ne peut sortir de la requête).
  static String pcQuery(String query) => query
      .replaceAll(RegExp(r"""[^\p{L}\p{N} _.+-]""", unicode: true), ' ')
      .split(RegExp(r'\s+'))
      .where((w) => w.length >= 2 && RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(w))
      .take(4)
      .join(' ');

  static Future<List<SearchHit>> pcFiles(String query, List<String> w) async {
    if (kIsWeb || !Platform.isWindows) return const [];
    final q = pcQuery(query);
    if (q.isEmpty) return const [];
    try {
      final r = await PowerShell.run(pcScript, {'q': q}, const Duration(seconds: 12));
      final t = '${r.stdout}'.trim();
      if (t.isEmpty) return const [];
      return [
        for (final f in _maps(jsonDecode(t)))
          SearchHit(
            source: 'PC',
            title: '${f['nom'] ?? ''}',
            detail: '${f['chemin'] ?? ''}',
            date: _date(f['modifie']),
            path: '${f['chemin'] ?? ''}',
            score: score(w, '${f['nom'] ?? ''}', '').clamp(1, 3).toDouble(),
          ),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Cherche partout. [call] lance un outil de Mon Hub ; [tools] = ceux
  /// qui existent. [onPart] reçoit les résultats au fur et à mesure.
  static Future<List<SearchHit>> run(
    String query,
    Future<Object?> Function(String tool, Map<String, dynamic> args) call,
    Set<String> tools, {
    void Function(List<SearchHit> all)? onPart,
    bool pc = true,
  }) async {
    final w = words(query);
    if (w.isEmpty) return const [];
    final all = <SearchHit>[];
    void got(List<SearchHit> hits) {
      if (hits.isEmpty) return;
      all.addAll(hits);
      onPart?.call(sorted(all));
    }

    await Future.wait([
      if (pc) pcFiles(query, w).then(got),
      for (final e in toolsFor(query).entries)
        if (tools.contains(e.key))
          call(
            e.key,
            e.value,
          ).timeout(const Duration(seconds: 12)).then((r) => got(fromTool(e.key, r, w))).catchError((Object _) {}),
    ]);
    return sorted(all);
  }

  /// Les meilleurs d'abord, puis les plus récents.
  static List<SearchHit> sorted(List<SearchHit> l) => [...l]
    ..sort((a, b) {
      final s = b.score.compareTo(a.score);
      if (s != 0) return s;
      return (b.date ?? DateTime(2000)).compareTo(a.date ?? DateTime(2000));
    });

  /// Ce que Nexo dit.
  static String say(String query, List<SearchHit> hits) {
    if (hits.isEmpty) return 'Je n\'ai rien trouvé pour « $query ».';
    final by = <String, int>{};
    for (final h in hits) {
      by[h.source] = (by[h.source] ?? 0) + 1;
    }
    final top = hits.first;
    return '${hits.length} résultat${hits.length > 1 ? 's' : ''} pour « $query » '
        '(${by.entries.map((e) => '${e.value} ${e.key}').join(', ')}). Le premier : ${top.title} (${top.source}).';
  }
}
