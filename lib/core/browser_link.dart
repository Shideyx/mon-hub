import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'error_log.dart';
import 'hub_module.dart';

/// Le lien entre Mon Hub et **l'extension Chrome** « Mon Hub — Clicky dans
/// le navigateur » (dossier `assets/chrome-extension`). Sur ce PC seulement
/// (127.0.0.1), et seulement avec cette extension-là (son identifiant fixe) :
/// une page web ne peut pas s'y brancher.
///
/// Clicky peut alors lister tes onglets, ouvrir ses propres onglets en
/// arrière-plan (groupe « Clicky »), lire une page, cliquer, écrire — pendant
/// que tu fais autre chose.
class BrowserLink extends ChangeNotifier {
  BrowserLink._();
  static final instance = BrowserLink._();

  static const port = 47614;

  /// Identifiant de l'extension (fixé par la clé de son manifest.json).
  static const extensionId = 'nejfhocplopdmnijfodbmcbelcciblji';

  HttpServer? _server;
  WebSocket? _ws;
  Timer? _ping;
  int _next = 0;
  final _waiting = <int, Completer<Object?>>{};
  String version = '';

  bool get connected => _ws != null;

  /// Ce que Clicky fait en ce moment dans le navigateur (pour la pastille).
  final step = ValueNotifier<String>('');

  /// Les actions dans le navigateur sont permises sans demander jusqu'à cette
  /// heure (pendant une tâche « fais-le à ma place »).
  DateTime? trustedUntil;
  bool get trusted => trustedUntil != null && DateTime.now().isBefore(trustedUntil!);

  /// La tâche a été arrêtée : plus aucune action.
  bool stopped = false;

  /// Demande l'accord pour un clic risqué (envoyer, publier, payer…).
  static Future<bool> Function(String what)? confirm;

  /// Seule l'extension Mon Hub (Chrome ou Edge) peut se brancher.
  static bool allowedOrigin(String? origin) {
    final o = (origin ?? '').toLowerCase();
    return o == 'chrome-extension://$extensionId' || o == 'extension://$extensionId';
  }

  Future<void> start() async {
    if (kIsWeb || _server != null) return;
    try {
      final s = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      _server = s;
      s.listen(_handle, onError: (Object _) {});
    } catch (e) {
      // Port déjà pris (un autre Mon Hub ouvert) : pas d'extension ici.
      debugPrint('Extension Chrome : $e');
    }
  }

  Future<void> stop() async {
    _ping?.cancel();
    await _ws?.close();
    _ws = null;
    await _server?.close(force: true);
    _server = null;
    notifyListeners();
  }

  Future<void> _handle(HttpRequest req) async {
    if (req.uri.path != '/navigateur' || !allowedOrigin(req.headers.value('origin')) ||
        !WebSocketTransformer.isUpgradeRequest(req)) {
      req.response.statusCode = HttpStatus.forbidden;
      await req.response.close();
      return;
    }
    final ws = await WebSocketTransformer.upgrade(req);
    await _ws?.close();
    _ws = ws;
    notifyListeners();
    // Un petit signe toutes les 20 s : l'extension reste éveillée.
    _ping?.cancel();
    _ping = Timer.periodic(const Duration(seconds: 20), (_) {
      try {
        ws.add(jsonEncode({'ping': DateTime.now().millisecondsSinceEpoch}));
      } catch (_) {}
    });
    ws.listen(
      (data) {
        try {
          final m = jsonDecode('$data');
          if (m is! Map) return;
          if (m['hello'] != null) version = '${m['version'] ?? ''}';
          final id = m['id'];
          if (id is int) {
            final c = _waiting.remove(id);
            if (c == null) return;
            m['ok'] == true ? c.complete(m['result']) : c.completeError('${m['error'] ?? 'erreur du navigateur'}');
          }
        } catch (_) {}
      },
      onDone: () => _gone(ws),
      onError: (Object _) => _gone(ws),
    );
  }

  void _gone(WebSocket ws) {
    if (!identical(_ws, ws)) return;
    _ws = null;
    _ping?.cancel();
    for (final c in _waiting.values) {
      if (!c.isCompleted) c.completeError('L\'extension s\'est déconnectée');
    }
    _waiting.clear();
    notifyListeners();
  }

  /// Envoie une commande à l'extension et attend la réponse.
  Future<Object?> call(String cmd, Map<String, dynamic> args, {Duration timeout = const Duration(seconds: 45)}) async {
    final ws = _ws;
    if (ws == null) {
      throw 'L\'extension Chrome de Mon Hub n\'est pas branchée : Réglages de Clicky → Clicky dans le navigateur.';
    }
    if (stopped) throw 'Tâche arrêtée.';
    final id = ++_next;
    final c = Completer<Object?>();
    _waiting[id] = c;
    ws.add(jsonEncode({'id': id, 'cmd': cmd, 'args': args}));
    try {
      return await c.future.timeout(timeout);
    } on TimeoutException {
      _waiting.remove(id);
      throw 'Le navigateur ne répond pas.';
    }
  }

  /// Un clic qui envoie, publie, paie ou supprime : il faut ton accord.
  static final risky = RegExp(
    r'envoy|send|publi|post(?:er)?\b|partag|share|pay|achet|buy|command|order|supprim|delete|remove|effac|'
    r'valider|confirm|submit|soumettre|rendre|d[ée]poser|inscri|abonn|subscribe|accept|signer|transf[ée]r',
    caseSensitive: false,
  );

  void _say(String s) => step.value = s;

  int _tab(Object? v) => (v as num?)?.toInt() ?? int.tryParse('$v') ?? (throw 'Numéro d\'onglet manquant');

  /// Les outils de Clicky pour le navigateur.
  List<HubTool> get tools => [
    HubTool(
      name: 'nav_onglets',
      description: 'Navigateur (extension Mon Hub) : les onglets ouverts (numéro, titre, adresse).',
      run: (_) async => call('tabs', {}),
    ),
    HubTool(
      name: 'nav_ouvrir',
      description:
          'Navigateur : ouvre une page dans un nouvel onglet de Clicky (en arrière-plan par défaut, groupe « Clicky »), '
          'et donne son numéro d\'onglet.',
      params: {
        'url': ('string', 'Adresse https://…'),
        'premier_plan': ('boolean', 'Montrer l\'onglet à la personne'),
      },
      required: ['url'],
      run: (a) async {
        _say('ouvre ${Uri.tryParse('${a['url']}')?.host ?? ''}');
        return call('open', {'url': '${a['url']}', 'background': a['premier_plan'] != true});
      },
    ),
    HubTool(
      name: 'nav_lire',
      description:
          'Navigateur : lit une page (titre, texte, et les éléments utilisables numérotés : liens, boutons, champs). '
          'Relis la page après chaque action qui la change. Pour un Google Doc, préfère doc_lire.',
      params: {'onglet': ('integer', 'Numéro de l\'onglet')},
      required: ['onglet'],
      run: (a) async {
        _say('lit la page');
        return call('read', {'tab': _tab(a['onglet'])});
      },
    ),
    HubTool(
      name: 'nav_cliquer',
      description: 'Navigateur : clique sur un élément numéroté de la page (donné par nav_lire).',
      params: {
        'onglet': ('integer', 'Numéro de l\'onglet'),
        'element': ('integer', 'Numéro de l\'élément (nav_lire)'),
      },
      required: ['onglet', 'element'],
      run: (a) async {
        final tab = _tab(a['onglet']);
        final d = await call('describe', {'tab': tab, 'el': '${a['element']}'});
        final label = d is Map ? '${d['texte'] ?? ''}' : '';
        // Envoyer, publier, payer, supprimer… : toujours ton accord.
        if (risky.hasMatch(label) || (d is Map && d['formulaire'] == true)) {
          final ok = await confirm?.call('cliquer sur « ${label.isEmpty ? 'ce bouton' : label} »') ?? false;
          if (!ok) return 'La personne a refusé ce clic.';
        }
        _say('clique sur « ${label.length > 40 ? '${label.substring(0, 40)}…' : label} »');
        return call('click', {'tab': tab, 'el': '${a['element']}'});
      },
    ),
    HubTool(
      name: 'nav_ecrire',
      description:
          'Navigateur : écrit dans un champ numéroté (nav_lire), ou là où se trouve le curseur sans numéro (éditeurs '
          'comme Google Slides). entree=true appuie sur Entrée après. Jamais de mot de passe.',
      params: {
        'onglet': ('integer', 'Numéro de l\'onglet'),
        'element': ('integer', 'Numéro du champ (facultatif)'),
        'texte': ('string', 'Le texte à écrire'),
        'remplacer': ('boolean', 'Remplacer ce qui est déjà écrit (oui par défaut)'),
        'entree': ('boolean', 'Appuyer sur Entrée après'),
      },
      required: ['onglet', 'texte'],
      run: (a) async {
        _say('écrit dans la page');
        return call('type', {
          'tab': _tab(a['onglet']),
          'el': a['element'],
          'text': '${a['texte']}',
          'replace': a['remplacer'] != false,
          'enter': a['entree'] == true,
        });
      },
    ),
    HubTool(
      name: 'nav_touche',
      description: 'Navigateur : appuie sur une touche dans l\'onglet (Enter, Tab, Escape, ArrowDown, ctrl+a…).',
      params: {
        'onglet': ('integer', 'Numéro de l\'onglet'),
        'touche': ('string', 'La touche ou le raccourci'),
      },
      required: ['onglet', 'touche'],
      run: (a) async {
        final k = '${a['touche']}';
        // Entrée peut envoyer un formulaire ou un message.
        if (RegExp(r'^(?:ctrl\+)?enter$', caseSensitive: false).hasMatch(k) && !trusted) {
          final ok = await confirm?.call('appuyer sur Entrée (ça peut envoyer quelque chose)') ?? false;
          if (!ok) return 'La personne a refusé.';
        }
        return call('key', {'tab': _tab(a['onglet']), 'key': k});
      },
    ),
    HubTool(
      name: 'nav_montrer',
      description: 'Navigateur : met un onglet au premier plan pour que la personne le voie.',
      params: {'onglet': ('integer', 'Numéro de l\'onglet')},
      required: ['onglet'],
      run: (a) async => call('focus', {'tab': _tab(a['onglet'])}),
    ),
    HubTool(
      name: 'nav_fermer',
      description: 'Navigateur : ferme un onglet (seulement ceux que Clicky a ouverts, sauf si la personne le demande).',
      params: {'onglet': ('integer', 'Numéro de l\'onglet')},
      required: ['onglet'],
      run: (a) async => call('close', {'tab': _tab(a['onglet'])}),
    ),
  ];

  /// Ce que l'IA doit savoir pour bien se servir du navigateur.
  static const guide =
      'Navigateur (extension Mon Hub, outils nav_…) : tu peux utiliser les sites web de la personne (elle y est '
      'connectée) sans prendre sa souris. Ouvre TES onglets avec nav_ouvrir (en arrière-plan), puis nav_lire pour voir '
      'les éléments numérotés, et nav_cliquer / nav_ecrire / nav_touche. Relis la page après chaque action qui la change. '
      'Ne ferme pas les onglets de la personne. Pour Google Docs, préfère doc_creer / doc_lire / doc_ecrire (plus '
      'fiable que taper dans la page). Ne saisis jamais de mot de passe. Les pages de banque, paiement et mots de passe '
      'sont bloquées. Avant d\'envoyer, publier, payer ou supprimer, l\'accord de la personne est demandé tout seul.';

  /// Garde la trace des erreurs du navigateur sans faire planter Clicky.
  static void record(Object e) => ErrorLog.record(e, null, where: 'Extension Chrome');
}
