import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../modules/youtube/youtube_module.dart' show YouTubeSearch, YtVideo;
import 'phone_link.dart';

/// Un son de la soirée.
class PartySong {
  PartySong({required this.id, required this.title, this.channel = '', this.length = '', this.by = '', this.guest = ''});
  final String id;
  final String guest;
  final String title;
  final String channel;
  final String length;
  final String by;
  final votes = <String>{};
  final added = DateTime.now();

  Map<String, Object> toJson(String guest) => {
    'id': id,
    'titre': title,
    'chaine': channel,
    'duree': length,
    'par': by,
    'votes': votes.length,
    'moi': votes.contains(guest),
  };
}

/// **Playlist de soirée** : les invités scannent un QR code, cherchent des
/// sons (YouTube, recherché par le PC), les ajoutent et votent ; le PC les
/// joue dans l'ordre des votes.
///
/// Les invités ont leur propre lien secret (`/soiree/<code>/`), qui ne donne
/// accès qu'à la soirée : jamais aux fichiers ni à la télécommande du PC.
class Party extends ChangeNotifier {
  Party._();
  static final instance = Party._();

  static const maxQueue = 100;
  static const maxPerGuest = 5;

  String? _code;
  PartySong? playing;
  final queue = <PartySong>[];
  bool _ownsServer = false;

  /// Recherche (remplaçable dans les tests).
  Future<List<YtVideo>> Function(String q) search = YouTubeSearch.search;

  bool get on => _code != null;

  /// Le lien des invités (QR code).
  Uri? get link {
    final b = PhoneLink.instance.base;
    final c = _code;
    if (b == null || c == null) return null;
    return b.replace(path: '/soiree/$c/');
  }

  /// Les sons à venir : les plus votés d'abord, puis par ordre d'arrivée.
  List<PartySong> get upcoming =>
      [...queue]..sort((a, b) {
        final v = b.votes.length.compareTo(a.votes.length);
        return v != 0 ? v : a.added.compareTo(b.added);
      });

  Future<void> start() async {
    if (_code != null) return;
    final link = PhoneLink.instance;
    if (!link.extraRoutes.contains(_route)) link.extraRoutes.add(_route);
    _ownsServer = !link.running;
    await link.start(force: true);
    final r = Random.secure();
    _code = [for (var i = 0; i < 12; i++) r.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
    notifyListeners();
  }

  Future<void> stop() async {
    _code = null;
    queue.clear();
    playing = null;
    final link = PhoneLink.instance;
    link.extraRoutes.remove(_route);
    if (_ownsServer && !link.enabled) await link.stop();
    _ownsServer = false;
    notifyListeners();
  }

  /// Le son suivant (le plus voté), ou null s'il n'y a plus rien.
  PartySong? next() {
    final list = upcoming;
    playing = list.isEmpty ? null : list.first;
    if (playing != null) queue.remove(playing);
    notifyListeners();
    return playing;
  }

  void remove(String id) {
    queue.removeWhere((s) => s.id == id);
    notifyListeners();
  }

  /// Ajouter un son (par l'hôte ou un invité). Renvoie un message d'erreur, ou null.
  String? add(PartySong s, String guest) {
    if (!RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(s.id)) return 'Son inconnu.';
    final same = queue.where((q) => q.id == s.id).firstOrNull;
    if (same != null || playing?.id == s.id) {
      same?.votes.add(guest);
      notifyListeners();
      return null;
    }
    if (queue.length >= maxQueue) return 'La file est pleine.';
    final mine = queue.where((q) => q.guest == guest).length;
    if (guest.isNotEmpty && mine >= maxPerGuest) return 'Tu as déjà $maxPerGuest sons en attente : vote pour les autres !';
    s.votes.add(guest);
    queue.add(s);
    notifyListeners();
    return null;
  }

  /// Ajoute ou retire le vote d'un invité.
  void vote(String id, String guest) {
    final s = queue.where((q) => q.id == id).firstOrNull;
    if (s == null || guest.isEmpty) return;
    if (!s.votes.remove(guest)) s.votes.add(guest);
    notifyListeners();
  }

  static String clean(Object? v, int max) {
    final t = '${v ?? ''}'.replaceAll(RegExp(r'[\x00-\x1F<>]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length > max ? t.substring(0, max) : t;
  }

  Map<String, Object?> state(String guest) => {
    'en_cours': playing?.toJson(guest),
    'file': [for (final s in upcoming) s.toJson(guest)],
  };

  final _lastSearch = <String, DateTime>{};

  Future<bool> _route(HttpRequest req, List<String> segs) async {
    if (segs.isEmpty || segs[0] != 'soiree') return false;
    final res = req.response;
    final code = _code;
    if (segs.length < 2 || code == null || !PhoneLink.sameKey(segs[1], code)) {
      await PhoneLink.send(res, 404, 'text/plain', utf8.encode('Cette soirée est terminée.'));
      return true;
    }
    if (segs.length == 2) {
      res.statusCode = 302;
      res.headers.set('Location', '/soiree/$code/');
      await res.close();
      return true;
    }
    final rest = segs.sublist(2).join('/');
    final guest = clean(req.uri.queryParameters['invite'], 40);
    switch (rest) {
      case '' || 'index.html':
        await PhoneLink.instance.asset(res, 'party/index.html');
      case 'party.js' || 'party.css':
        await PhoneLink.instance.asset(res, 'party/$rest');
      case 'icone.png':
        await PhoneLink.instance.asset(res, 'logo.png');
      case 'api/etat':
        await PhoneLink.sendJson(res, state(guest));
      case 'api/chercher':
        final q = clean(req.uri.queryParameters['q'], 80);
        final last = _lastSearch[guest];
        if (q.isEmpty || (last != null && DateTime.now().difference(last) < const Duration(milliseconds: 800))) {
          await PhoneLink.sendJson(res, {'resultats': []});
          break;
        }
        _lastSearch[guest] = DateTime.now();
        List<YtVideo> found = const [];
        try {
          found = await search(q);
        } catch (_) {}
        await PhoneLink.sendJson(res, {
          'resultats': [for (final v in found.take(8)) v.toJson()],
        });
      case 'api/ajouter' when req.method == 'POST':
        final m = _json(await PhoneLink.readText(req, 8 * 1024));
        final err = add(
          PartySong(
            id: clean(m['id'], 11),
            title: clean(m['titre'], 120),
            channel: clean(m['chaine'], 60),
            length: clean(m['duree'], 10),
            by: clean(m['nom'], 20),
            guest: guest,
          ),
          guest,
        );
        await PhoneLink.sendJson(res, {'ok': err == null, 'message': err ?? 'Ajouté ✅'});
      case 'api/voter' when req.method == 'POST':
        final m = _json(await PhoneLink.readText(req, 4 * 1024));
        vote(clean(m['id'], 11), guest);
        await PhoneLink.sendJson(res, {'ok': true});
      default:
        await PhoneLink.send(res, 404, 'text/plain', const []);
    }
    return true;
  }

  static Map<String, dynamic> _json(String? s) {
    try {
      final d = jsonDecode(s ?? '');
      return d is Map<String, dynamic> ? d : {};
    } catch (_) {
      return {};
    }
  }
}
