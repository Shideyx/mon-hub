import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

/// La session (jeton) a expiré : il faut se reconnecter.
class EdSessionExpired implements Exception {
  const EdSessionExpired();
  @override
  String toString() => 'Session École Directe expirée';
}

/// École Directe refuse l'identifiant, le mot de passe ou la réponse de
/// sécurité. Mon Hub ne doit **pas** réessayer tout seul : chaque essai raté
/// rapproche du blocage du compte.
class EdAuthError implements Exception {
  const EdAuthError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Client pour l'API **non officielle** d'École Directe (celle qu'utilise
/// leur propre site). Elle n'est pas documentée et change de temps en temps :
/// si la connexion casse après une mise à jour d'École Directe, c'est ici
/// qu'il faut corriger.
class EdClient {
  /// [paced] : laisse un petit délai variable entre deux requêtes, comme une
  /// vraie personne sur le site (désactivé dans les tests).
  EdClient([http.Client? client, this.paced = true]) : _http = client ?? http.Client();

  final bool paced;
  DateTime? _lastRequest;
  final _rnd = math.Random();

  /// Pas de rafale : au moins ~0,7 à 1,6 s entre deux requêtes.
  Future<void> _pace() async {
    if (!paced) return;
    final last = _lastRequest;
    if (last != null) {
      final gap = Duration(milliseconds: 700 + _rnd.nextInt(900));
      final wait = gap - DateTime.now().difference(last);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
    }
    _lastRequest = DateTime.now();
  }

  static const _base = 'https://api.ecoledirecte.com/v3';

  /// Même profil que le site officiel www.ecoledirecte.com (suivi sur les
  /// clients libres qui fonctionnent en 2026). École Directe lie le jeton à
  /// l'User-Agent : il doit être identique sur toutes les requêtes.
  static const _v = '4.101.4';
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/146.0.0.0 Safari/537.36';
  final http.Client _http;

  String? token;
  String? _twoFa;
  String? _gtk;
  int? accountId;
  String? studentName;

  /// Identifiant d'appareil (le site officiel envoie une valeur vide).
  String uuid = '';
  final Map<String, String> _cookies = {};

  Map<String, String> _headers({bool gtk = false}) => {
    'Content-Type': 'application/x-www-form-urlencoded',
    'Accept': 'application/json, text/plain, */*',
    'Accept-Language': 'fr-FR,fr;q=0.9,en;q=0.8',
    // Comme une requête partie du site officiel.
    'Origin': 'https://www.ecoledirecte.com',
    'Referer': 'https://www.ecoledirecte.com/',
    'User-Agent': _ua,
    if (_cookies.isNotEmpty)
      'Cookie': _cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
    if (gtk && (_gtk ?? _cookies['GTK']) != null) 'X-Gtk': (_gtk ?? _cookies['GTK'])!,
    'X-Token': ?token,
    '2fa-token': ?_twoFa,
  };

  void _keep(http.BaseResponse res) {
    final raw = res.headers['set-cookie'];
    if (raw != null) {
      // package:http fusionne plusieurs Set-Cookie avec des virgules.
      for (final m in RegExp(r'(?:^|,)\s*([A-Za-z0-9_\-]+)=([^;,]*)').allMatches(raw)) {
        _cookies[m.group(1)!] = m.group(2)!;
      }
    }
    final g = res.headers['x-gtk'];
    if (g != null && g.isNotEmpty) _gtk = g;
    final t = res.headers['x-token'];
    if (t != null && t.isNotEmpty) token = t;
    final f = res.headers['2fa-token'];
    if (f != null && f.isNotEmpty) _twoFa = f;
  }

  /// Corps de requête : `data=` + le JSON **encodé pour un formulaire**.
  /// Indispensable : la réponse à la question de sécurité et les codes de
  /// validation sont en base64 et contiennent des « + », que le serveur
  /// lirait sinon comme des espaces (la réponse arrivait abîmée).
  static String body(Map<String, dynamic> data) => 'data=${Uri.encodeComponent(jsonEncode(data))}';

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> data, {
    bool gtk = false,
    bool session = true,
  }) async {
    final sep = path.contains('?') ? '&' : '?';
    await _pace();
    final http.Response res;
    try {
      res = await _http
          .post(
            Uri.parse('$_base$path${sep}v=$_v'),
            headers: _headers(gtk: gtk),
            body: body(data),
          )
          .timeout(const Duration(seconds: 25));
    } catch (e) {
      throw 'École Directe injoignable (vérifie ta connexion internet) : $e';
    }
    _keep(res);
    final text = utf8.decode(res.bodyBytes, allowMalformed: true).trim();
    if (!text.startsWith('{')) {
      final code = res.headers['x-code'] ?? '${res.statusCode}';
      return {'code': int.tryParse(code) ?? res.statusCode, 'message': '', 'data': null};
    }
    final j = jsonDecode(text) as Map<String, dynamic>;
    final t = j['token'];
    if (t is String && t.isNotEmpty) token = t;
    // Jeton périmé sur une requête de données : on se reconnectera (une
    // seule fois), au lieu d'enchaîner les erreurs.
    if (session && (j['code'] == 520 || j['code'] == 525)) throw const EdSessionExpired();
    return j;
  }

  /// `GET login.awp?gtk=1` : jeton anti-falsification (GTK) que la connexion
  /// renvoie dans l'en-tête X-Gtk. Le site officiel le redemande avant
  /// **chaque** connexion, y compris celle qui suit la question de sécurité.
  Future<void> _bootstrapGtk() async {
    _gtk = null;
    await _pace();
    final http.Response g;
    try {
      g = await _http
          .get(Uri.parse('$_base/login.awp?gtk=1&v=$_v'), headers: _headers())
          .timeout(const Duration(seconds: 25));
    } catch (e) {
      throw 'École Directe injoignable (vérifie ta connexion internet) : $e';
    }
    _keep(g);
    try {
      final j = jsonDecode(utf8.decode(g.bodyBytes)) as Map;
      final t = j['token'];
      if (t is String && t.isNotEmpty) _gtk = t;
    } catch (_) {
      // Corps vide : le GTK est dans le cookie.
    }
  }

  static String explain(Map<String, dynamic> r) {
    final msg = '${r['message'] ?? ''}'.trim();
    return switch (r['code']) {
      505 => msg.isNotEmpty ? msg : 'Identifiant ou mot de passe incorrect',
      516 => 'Compte désactivé ou établissement fermé',
      517 => 'École Directe a changé sa version : mets à jour Mon Hub',
      520 || 525 => 'Session expirée, reconnecte-toi',
      535 => 'École Directe est en maintenance',
      _ => msg.isNotEmpty ? '$msg (code ${r['code']})' : 'Échec de connexion (code ${r['code']})',
    };
  }

  /// Connexion. [answerQuestion] est appelé si École Directe pose sa
  /// question de sécurité (double authentification) : il reçoit la question
  /// et les choix, et doit renvoyer le choix sélectionné.
  ///
  /// Suit pas à pas le site officiel : GTK → connexion → (code 250) question
  /// → réponse → nouveau GTK → connexion finale avec `cn`/`cv` en haut du
  /// message **et** dans `fa`, avec les jetons X-Token et 2FA-Token.
  Future<void> login(
    String user,
    String password, {
    required Future<String?> Function(String question, List<String> choices) answerQuestion,
    List<Map<String, String>>? savedFa,
  }) async {
    token = null;
    _twoFa = null;
    _gtk = null;
    _cookies.clear();
    lastFa = null;

    // Facteurs déjà validés (évite de reposer la question à chaque fois).
    final answered = <Map<String, String>>[
      for (final f in savedFa ?? const <Map<String, String>>[])
        if (f['cn'] != null && f['cv'] != null) {'cn': f['cn']!, 'cv': f['cv']!},
    ];
    List<Map<String, dynamic>> faList() => [
      for (final f in answered) {...f, 'uniq': false},
    ];
    Map<String, dynamic> credentials() => {
      'identifiant': user.trim(),
      'motdepasse': password,
      'isReLogin': false,
    };

    await _bootstrapGtk();
    var r = await _post(
      '/login.awp',
      {...credentials(), 'uuid': uuid, 'fa': faList()},
      gtk: true,
      session: false,
    );
    if (r['code'] == 505 && answered.isNotEmpty) {
      // Les facteurs gardés ne sont plus valables : on recommence sans.
      return login(user, password, answerQuestion: answerQuestion);
    }

    var rounds = 0;
    while (r['code'] == 250) {
      // École Directe peut enchaîner deux questions ; au-delà, c'est qu'il
      // refuse quelque chose (et chaque essai compte sur un compte qui se
      // bloque) : on s'arrête.
      if (++rounds > 3) throw 'École Directe repose sans cesse la question de sécurité';
      final q = await _post('/connexion/doubleauth.awp?verbe=get', {}, session: false);
      if (q['code'] != 200 || q['data'] is! Map) {
        throw 'Question de sécurité indisponible : ${explain(q)}';
      }
      final d = q['data'] as Map<String, dynamic>;
      String b64(String s) => utf8.decode(base64.decode(s), allowMalformed: true);
      final question = b64('${d['question']}');
      final choices = [for (final p in (d['propositions'] as List? ?? const [])) '$p'];
      final decoded = choices.map(b64).toList();
      final picked = await answerQuestion(question, decoded);
      if (picked == null) throw 'Réponds à la question de sécurité pour te connecter';
      final enc = choices[decoded.indexOf(picked)];
      final a = await _post('/connexion/doubleauth.awp?verbe=post', {'choix': enc}, session: false);
      final ad = a['data'];
      final cn = ad is Map ? ad['cn'] : null;
      final cv = ad is Map ? ad['cv'] : null;
      if (a['code'] != 200 || cn is! String || cv is! String) {
        throw EdAuthError('Mauvaise réponse à la question de sécurité (${explain(a)})');
      }
      answered
        ..removeWhere((f) => f['cn'] == cn)
        ..add({'cn': cn, 'cv': cv});
      await _bootstrapGtk();
      r = await _post(
        '/login.awp',
        {...credentials(), 'cn': cn, 'cv': cv, 'uuid': uuid, 'fa': faList()},
        gtk: true,
        session: false,
      );
    }
    if (r['code'] == 505 || r['code'] == 516) throw EdAuthError(explain(r));
    if (r['code'] != 200) throw explain(r);
    if (answered.isNotEmpty) lastFa = answered;
    final accounts = (r['data'] as Map?)?['accounts'] as List? ?? [];
    if (accounts.isEmpty) throw 'Aucun compte trouvé sur ce profil École Directe';
    final acc = accounts.first as Map;
    if ('${acc['typeCompte']}' == '1' || '${acc['typeCompte']}' == 'P') {
      // Compte parent : on prend le premier enfant.
      final kids = (acc['profile'] as Map?)?['eleves'] as List? ?? [];
      if (kids.isEmpty) throw 'Compte parent sans élève associé';
      final k = kids.first as Map;
      accountId = k['id'] as int;
      studentName = '${k['prenom']} ${k['nom']}';
    } else {
      accountId = acc['id'] as int;
      studentName = '${acc['prenom']} ${acc['nom']}';
    }
  }

  /// Après une double authentification réussie : à mémoriser pour éviter
  /// de répondre à la question à chaque fois.
  List<Map<String, String>>? lastFa;

  Future<List<EdGrade>> grades() async {
    final r = await _post('/eleves/$accountId/notes.awp?verbe=get', {'anneeScolaireId': ''});
    if (r['code'] != 200) throw 'Notes indisponibles (code ${r['code']})';
    final list = (r['data']?['notes'] as List? ?? [])
        .map((e) => EdGrade.fromJson(e as Map<String, dynamic>))
        .where((g) => g.value.isNotEmpty)
        .toList();
    list.sort((a, b) => (b.date ?? DateTime(0)).compareTo(a.date ?? DateTime(0)));
    return list;
  }

  static String _b64(String? s) {
    if (s == null || s.isEmpty) return '';
    try {
      return utf8.decode(base64.decode(s), allowMalformed: true);
    } catch (_) {
      return s;
    }
  }

  static String htmlToText(String html) => html
      .replaceAll(RegExp(r'<br\s*/?>|</p>|</div>|</li>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&#39;', "'")
      .replaceAll('&quot;', '"')
      .replaceAll(RegExp(r'\n\s*\n\s*\n+'), '\n\n')
      .trim();

  /// Année scolaire au format « 2026-2027 ».
  static String schoolYear([DateTime? d]) {
    final n = d ?? DateTime.now();
    final start = n.month >= 8 ? n.year : n.year - 1;
    return '$start-${start + 1}';
  }

  /// Messages reçus dans la messagerie École Directe.
  Future<List<EdMessage>> messages() async {
    final r = await _post(
      '/eleves/$accountId/messages.awp?force=false&typeRecuperation=received&idClasseur=0'
      '&orderBy=date&order=desc&query=&onlyRead=&page=0&itemsPerPage=30&getAll=0&verbe=get',
      {'anneeMessages': schoolYear()},
    );
    if (r['code'] != 200) throw 'Messagerie indisponible (code ${r['code']})';
    final list = r['data']?['messages']?['received'] as List? ?? [];
    return list.map((e) => EdMessage.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// Contenu d'un message (texte).
  Future<String> messageContent(int id) async {
    final r = await _post('/eleves/$accountId/messages/$id.awp?verbe=get&mode=destinataire', {
      'anneeMessages': schoolYear(),
    });
    if (r['code'] != 200) throw 'Message indisponible (code ${r['code']})';
    return htmlToText(_b64(r['data']?['content'] as String?));
  }

  /// Répond à l'expéditeur d'un message.
  Future<void> reply(EdMessage original, String text) async {
    final f = original.sender;
    if (f['id'] == null) throw 'Impossible de répondre à ce message';
    final html = '<p>${const HtmlEscape().convert(text).replaceAll('\n', '<br>')}</p>';
    final subject = original.subject.toLowerCase().startsWith('re')
        ? original.subject
        : 'RE : ${original.subject}';
    final r = await _post('/eleves/$accountId/messages.awp?verbe=post', {
      'message': {
        'groupesDestinataires': [
          {
            'destinataires': [
              {...f, 'type': f['role'] ?? f['type'] ?? 'P', 'isSelected': true, 'to_cc_cci': 'to'},
            ],
            'selected': true,
          },
        ],
        'content': base64.encode(utf8.encode(html)),
        'subject': subject,
        'files': [],
        'parentID': original.id,
      },
      'anneeMessages': schoolYear(),
    });
    if (r['code'] != 200) {
      throw (r['message'] as String?)?.isNotEmpty == true
          ? r['message'] as String
          : 'Envoi refusé par École Directe (code ${r['code']})';
    }
  }

  /// Devoirs à venir, avec leur contenu.
  Future<List<EdHomework>> homework() async {
    final r = await _post('/Eleves/$accountId/cahierdetexte.awp?verbe=get', {});
    if (r['code'] != 200) throw 'Cahier de texte indisponible (code ${r['code']})';
    final days = (r['data'] as Map<String, dynamic>? ?? {}).keys.toList()..sort();
    final out = <EdHomework>[];
    for (final day in days.take(7)) {
      final d = await _post('/Eleves/$accountId/cahierdetexte/$day.awp?verbe=get', {});
      for (final m in (d['data']?['matieres'] as List? ?? [])) {
        final todo = m['aFaire'];
        if (todo == null) continue;
        out.add(
          EdHomework(
            '${todo['idDevoir'] ?? '$day${m['matiere']}'}',
            DateTime.tryParse(day) ?? DateTime.now(),
            m['matiere'] as String? ?? '',
            htmlToText(_b64(todo['contenu'] as String?)),
            todo['effectue'] == true,
            m['interrogation'] == true,
          ),
        );
      }
    }
    return out;
  }

  Future<List<EdLesson>> timetable(DateTime from, DateTime to) async {
    String d(DateTime x) => x.toIso8601String().substring(0, 10);
    final r = await _post('/E/$accountId/emploidutemps.awp?verbe=get', {
      'dateDebut': d(from),
      'dateFin': d(to),
      'avecTrous': false,
    });
    if (r['code'] != 200) throw 'Emploi du temps indisponible (code ${r['code']})';
    return (r['data'] as List).map((e) => EdLesson.fromJson(e as Map<String, dynamic>)).toList()
      ..sort((a, b) => a.start.compareTo(b.start));
  }
}

class EdMessage {
  EdMessage(this.id, this.subject, this.from, this.date, this.read, [this.sender = const {}]);
  final int id;
  final String subject;
  final String from;
  final DateTime? date;
  bool read;

  /// Fiche brute de l'expéditeur (sert à lui répondre).
  final Map<String, dynamic> sender;

  factory EdMessage.fromJson(Map<String, dynamic> j) {
    final f = j['from'] as Map<String, dynamic>? ?? const {};
    final name =
        (f['name'] as String?) ??
        [f['civilite'], f['prenom'], f['nom']].whereType<String>().join(' ').trim();
    return EdMessage(
      j['id'] as int? ?? 0,
      j['subject'] as String? ?? '(sans objet)',
      name.isEmpty ? '?' : name,
      DateTime.tryParse('${j['date'] ?? ''}'.replaceFirst(' ', 'T')),
      j['read'] == true,
      f,
    );
  }
}

class EdHomework {
  EdHomework(this.id, this.due, this.subject, this.content, this.done, this.isTest);
  final String id;
  final DateTime due;
  final String subject;
  final String content;
  final bool done;
  final bool isTest;
}

class EdGrade {
  EdGrade(this.id, this.subject, this.value, this.outOf, this.title, this.date);
  final String id;
  final String subject;
  final String value;
  final String outOf;
  final String title;
  final DateTime? date;

  factory EdGrade.fromJson(Map<String, dynamic> j) => EdGrade(
    '${j['id']}',
    j['libelleMatiere'] as String? ?? '',
    '${j['valeur'] ?? ''}'.trim(),
    '${j['noteSur'] ?? '20'}'.trim(),
    j['devoir'] as String? ?? '',
    DateTime.tryParse(j['date'] as String? ?? ''),
  );
}

class EdLesson {
  EdLesson(
    this.subject,
    this.start,
    this.end,
    this.room,
    this.teacher,
    this.cancelled, [
    this.color,
  ]);
  final String subject;
  final DateTime start;
  final DateTime end;
  final String room;
  final String teacher;
  final bool cancelled;

  /// Couleur de la matière choisie par l'établissement (#rrggbb).
  final String? color;

  factory EdLesson.fromJson(Map<String, dynamic> j) => EdLesson(
    (j['matiere'] as String?)?.isNotEmpty == true
        ? j['matiere'] as String
        : (j['text'] as String? ?? 'Cours'),
    DateTime.parse((j['start_date'] as String).replaceFirst(' ', 'T')),
    DateTime.parse((j['end_date'] as String).replaceFirst(' ', 'T')),
    j['salle'] as String? ?? '',
    j['prof'] as String? ?? '',
    j['isAnnule'] == true,
    j['color'] as String?,
  );
}
