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

  /// Compte parent : la messagerie est celle de la famille
  /// (`/familles/{id}`), pas celle de l'élève.
  int? familyId;

  /// Année scolaire donnée par École Directe à la connexion (« 2026-2027 »).
  String? year;

  /// Chemin de la messagerie : élève, ou famille pour un compte parent.
  String get _mailbox => familyId != null ? '/familles/$familyId' : '/eleves/$accountId';
  String get _year => (year != null && RegExp(r'^\d{4}-\d{4}$').hasMatch(year!)) ? year! : schoolYear();

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
    if (_cookies.isNotEmpty) 'Cookie': _cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
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
    Map<String, dynamic> credentials() => {'identifiant': user.trim(), 'motdepasse': password, 'isReLogin': false};

    await _bootstrapGtk();
    var r = await _post('/login.awp', {...credentials(), 'uuid': uuid, 'fa': faList()}, gtk: true, session: false);
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
    final y = '${acc['anneeScolaireCourante'] ?? ''}';
    year = y.isEmpty ? null : y;
    if ('${acc['typeCompte']}' != 'E') {
      // Compte parent (« 1 » ou « P ») : on prend le premier enfant, et la
      // messagerie est celle de la famille.
      final kids = (acc['profile'] as Map?)?['eleves'] as List? ?? [];
      if (kids.isEmpty) throw 'Compte parent sans élève associé';
      final k = kids.first as Map;
      accountId = _int(k['id']);
      familyId = _int(acc['id']);
      studentName = '${k['prenom']} ${k['nom']}';
    } else {
      accountId = _int(acc['id']);
      familyId = null;
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

  static int? _int(Object? v) => v is int ? v : int.tryParse('${v ?? ''}');

  /// Texte lisible à partir du HTML d'École Directe : sans balises ni mise
  /// en forme Word, accents (`&eacute;`, `&#233;`…) remis, sauts de ligne
  /// gardés.
  static String htmlToText(String html) {
    var s = html.replaceAll('\r\n', '\n');
    // Copié-collé depuis Word : commentaires conditionnels, styles, XML.
    s = s.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
    s = s.replaceAll(
      RegExp(r'<(style|script|head|xml|title)\b[^>]*>.*?</\1\s*>', caseSensitive: false, dotAll: true),
      '',
    );
    // Les retours à la ligne du code HTML ne comptent pas, les balises si.
    // Les blocs (paragraphes, listes…) mettent un \u0001 : plusieurs à la
    // suite ne font qu'un saut de ligne.
    const block = '\u0001';
    s = s.replaceAll(RegExp(r'\s*\n\s*'), ' ');
    s = s.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    s = s.replaceAll(RegExp(r'<li\b[^>]*>', caseSensitive: false), '$block• ');
    s = s.replaceAll(RegExp(r'</?(p|div|li|tr|h[1-6]|ul|ol|table|blockquote)\b[^>]*>', caseSensitive: false), block);
    s = s.replaceAll(RegExp(r'</t[dh]\s*>', caseSensitive: false), '  ');
    s = s.replaceAll(RegExp(r'<[^>]*>'), '');
    s = decodeEntities(s);
    // HTML échappé deux fois (« &lt;p&gt; ») : on recommence une fois.
    if (RegExp(r'<(p|br|div|span|/p|/div|strong|b|i|u|a|font|li)\b', caseSensitive: false).hasMatch(s)) {
      return htmlToText(s.replaceAll(block, '<br>'));
    }
    s = s.replaceAll(RegExp('[ \\t]*$block[$block \\t]*'), '\n');
    final lines = [for (final l in s.split('\n')) l.replaceAll(RegExp(r'[ \t ]+'), ' ').trim()];
    return lines.join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  static final Map<String, String> _entities = () {
    final m = <String, String>{
      'nbsp': ' ',
      'amp': '&',
      'lt': '<',
      'gt': '>',
      'quot': '"',
      'apos': "'",
      'rsquo': '’',
      'lsquo': '‘',
      'rdquo': '”',
      'ldquo': '“',
      'laquo': '«',
      'raquo': '»',
      'hellip': '…',
      'ndash': '–',
      'mdash': '—',
      'euro': '€',
      'deg': '°',
      'bull': '•',
      'middot': '·',
      'copy': '©',
      'reg': '®',
      'trade': '™',
      'times': '×',
      'divide': '÷',
      'sup2': '²',
      'sup3': '³',
      'frac12': '½',
      'frac14': '¼',
      'frac34': '¾',
      'para': '¶',
      'sect': '§',
      'oelig': 'œ',
      'OElig': 'Œ',
      'aelig': 'æ',
      'AElig': 'Æ',
      'ccedil': 'ç',
      'Ccedil': 'Ç',
      'szlig': 'ß',
      'iexcl': '¡',
      'iquest': '¿',
      'pound': '£',
      'cent': '¢',
      'yen': '¥',
      'plusmn': '±',
      'micro': 'µ',
      'shy': '',
      'zwnj': '',
      'zwj': '',
      'lrm': '',
      'rlm': '',
      'thinsp': ' ',
      'ensp': ' ',
      'emsp': ' ',
      'rarr': '→',
      'larr': '←',
      'harr': '↔',
      'uarr': '↑',
      'darr': '↓',
      'le': '≤',
      'ge': '≥',
      'ne': '≠',
      'infin': '∞',
      'check': '✓',
      'ordm': 'º',
      'ordf': 'ª',
    };
    // Lettres accentuées : agrave, Eacute, ocirc, uuml, ntilde…
    const marks = {
      'grave': 'àèìòùÀÈÌÒÙ',
      'acute': 'áéíóúýÁÉÍÓÚÝ',
      'circ': 'âêîôûÂÊÎÔÛ',
      'uml': 'äëïöüÿÄËÏÖÜŸ',
      'tilde': 'ãõñÃÕÑ',
    };
    const bases = {
      'grave': 'aeiouAEIOU',
      'acute': 'aeiouyAEIOUY',
      'circ': 'aeiouAEIOU',
      'uml': 'aeiouyAEIOUY',
      'tilde': 'aonAON',
    };
    for (final e in marks.entries) {
      final b = bases[e.key]!;
      for (var i = 0; i < b.length; i++) {
        m['${b[i]}${e.key}'] = e.value[i];
      }
    }
    return m;
  }();

  /// Remplace les entités HTML (`&eacute;`, `&#233;`, `&#xE9;`…).
  static String decodeEntities(String s) =>
      s.replaceAllMapped(RegExp(r'&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[A-Za-z][A-Za-z0-9]{1,8});'), (m) {
        final e = m[1]!;
        if (e.startsWith('#')) {
          final hex = e.length > 1 && (e[1] == 'x' || e[1] == 'X');
          final code = int.tryParse(hex ? e.substring(2) : e.substring(1), radix: hex ? 16 : 10);
          if (code == null || code == 0 || code > 0x10FFFF) return m[0]!;
          // Windows-1252 glissé dans le HTML (&#146; = ’).
          const cp1252 = {
            128: '€',
            130: '‚',
            132: '„',
            133: '…',
            145: '‘',
            146: '’',
            147: '“',
            148: '”',
            149: '•',
            150: '–',
            151: '—',
            156: 'œ',
            140: 'Œ',
          };
          return cp1252[code] ?? String.fromCharCode(code);
        }
        return _entities[e] ?? _entities[e.toLowerCase()] ?? m[0]!;
      });

  /// Octets → texte : UTF-8, sinon l'ancien encodage Windows (Latin-1).
  static String decodeBytes(List<int> bytes) => _utf8(bytes) ?? latin1.decode(bytes, allowInvalid: true);

  static String? _utf8(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return null;
    }
  }

  /// Le texte a l'air d'être du vrai texte (pas des octets au hasard).
  static bool _looksText(String s) {
    if (s.isEmpty) return false;
    final bad = s.runes.where((r) => (r < 32 && r != 9 && r != 10 && r != 13) || r == 0xFFFD).length;
    return bad <= s.length * 0.02;
  }

  /// Contenu d'un message ou d'un devoir : du HTML en base64 (parfois avec
  /// des retours à la ligne), ou directement du HTML / du texte.
  static String decodeContent(String? raw) {
    var s = (raw ?? '').trim();
    if (s.isEmpty) return '';
    final compact = s.replaceAll(RegExp(r'\s+'), '');
    if (compact.length >= 8 && RegExp(r'^[A-Za-z0-9+/_-]+={0,2}$').hasMatch(compact)) {
      try {
        final bytes = base64.decode(base64.normalize(compact.replaceAll('-', '+').replaceAll('_', '/')));
        // Un vrai contenu codé : du HTML, ou un texte UTF-8 propre assez
        // long (un mot comme « Rappeler » n'est pas du base64).
        final u = _utf8(bytes);
        final t = u ?? latin1.decode(bytes, allowInvalid: true);
        final html = t.contains('<') && t.contains('>');
        if (_looksText(t) && (html || (u != null && (t.contains(' ') || compact.length >= 24)))) s = t;
      } catch (_) {}
    }
    return htmlToText(s);
  }

  /// Année scolaire au format « 2026-2027 ».
  static String schoolYear([DateTime? d]) {
    final n = d ?? DateTime.now();
    // Comme le site officiel : l'année change en septembre.
    final start = n.month >= 9 ? n.year : n.year - 1;
    return '$start-${start + 1}';
  }

  /// Messages d'un dossier de la messagerie : `received` (reçus), `sent`
  /// (envoyés) ou `archived` (archivés).
  ///
  /// Mêmes paramètres que le site officiel (et qu'Ecole Directe Plus) :
  /// `getAll=1`, l'année scolaire donnée à la connexion, et la messagerie de
  /// la famille pour un compte parent.
  Future<List<EdMessage>> messages({String folder = 'received'}) async {
    Future<Map<String, dynamic>> get(String y) => _post(
      '$_mailbox/messages.awp?force=false&typeRecuperation=$folder&idClasseur=0'
      '&orderBy=date&order=desc&query=&onlyRead=&getAll=1&verbe=get',
      {'anneeMessages': y},
    );
    var r = await get(_year);
    if (r['code'] != 200) throw _messagesError(r);
    var list = parseMessages(r['data'], folder);
    // Rentrée : École Directe peut encore ranger les messages sous l'année
    // d'avant (ou déjà sous la suivante) quelques jours.
    if (list.isEmpty && folder == 'received') {
      final y = _year.split('-').map(int.parse).toList();
      final other = DateTime.now().month >= 9 ? '${y[0] - 1}-${y[0]}' : '${y[1]}-${y[1] + 1}';
      final r2 = await get(other);
      if (r2['code'] == 200) {
        final l2 = parseMessages(r2['data'], folder);
        if (l2.isNotEmpty) {
          r = r2;
          list = l2;
        }
      }
    }
    final param = (r['data'] is Map) ? (r['data'] as Map)['parametrage'] : null;
    if (list.isEmpty && param is Map && param['isActif'] == false) {
      throw 'La messagerie est désactivée pour ton compte par ton établissement.';
    }
    return list;
  }

  String _messagesError(Map<String, dynamic> r) => switch (r['code']) {
    520 || 525 => 'Session expirée, reconnecte-toi',
    403 => 'Ton établissement n\'autorise pas la messagerie pour ce compte',
    _ => 'Messagerie indisponible (${explain(r)})',
  };

  /// Lit la liste des messages, quelle que soit la forme renvoyée.
  static List<EdMessage> parseMessages(Object? data, String folder) {
    if (data is! Map) return const [];
    final m = data['messages'];
    final Object? raw = m is Map ? (m[folder] ?? m['received']) : m;
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e is Map) EdMessage.fromJson(e.cast<String, dynamic>(), sent: folder == 'sent'),
    ];
  }

  /// Contenu d'un message (texte) et ses pièces jointes.
  Future<EdMessageContent> message(int id, {bool sent = false}) async {
    final mode = sent ? 'expediteur' : 'destinataire';
    var r = await _post('$_mailbox/messages/$id.awp?verbe=get&mode=$mode', {'anneeMessages': _year});
    if (r['code'] != 200 || r['data'] is! Map) {
      // Message d'une autre année scolaire, ou rangé de l'autre côté.
      r = await _post('$_mailbox/messages/$id.awp?verbe=get&mode=${sent ? 'destinataire' : 'expediteur'}', {
        'anneeMessages': _year,
      });
    }
    if (r['code'] != 200 || r['data'] is! Map) {
      throw 'Message indisponible (${explain(r)})';
    }
    return EdMessageContent.fromJson((r['data'] as Map).cast<String, dynamic>());
  }

  /// Contenu d'un message (texte seulement).
  Future<String> messageContent(int id) async => (await message(id)).text;

  /// Télécharge une pièce jointe (octets du fichier).
  Future<List<int>> attachment(EdAttachment f, {String? fileId}) async {
    await _pace();
    final uri = Uri.parse(
      '$_base/telechargement.awp?verbe=get&fichierId=${Uri.encodeQueryComponent(fileId ?? '${f.id}')}'
      '&leTypeDeFichier=${f.type.isEmpty ? 'PIECE_JOINTE' : f.type}&anneeMessages=$_year&v=$_v',
    );
    final res = await _http
        .post(uri, headers: _headers(), body: body({'forceDownload': 0}))
        .timeout(const Duration(seconds: 60));
    _keep(res);
    if (res.statusCode >= 400 || res.bodyBytes.isEmpty) {
      throw 'Pièce jointe indisponible (code ${res.statusCode})';
    }
    final head = utf8.decode(res.bodyBytes.take(40).toList(), allowMalformed: true).trimLeft();
    if (head.startsWith('{"code"')) throw 'Pièce jointe indisponible';
    return res.bodyBytes;
  }

  /// Cloud École Directe : un dossier et ce qu'il contient. Sans
  /// [folderId] : la racine de ton cloud.
  ///
  /// Comme le site officiel (`cloud/E/{id}.awp`, compte parent :
  /// `cloud/P/{id}`, espace de travail : `cloud/W/{id}.awp`) ; les
  /// sous-dossiers pas encore chargés se demandent avec `idfolder`.
  Future<EdCloudNode> cloud({String? folderId, String? owner}) async {
    final who = owner ?? (familyId != null ? 'P/$familyId' : 'E/$accountId');
    final q = folderId == null ? '' : '&idfolder=${Uri.encodeQueryComponent(folderId)}';
    var r = await _post('/cloud/$who.awp?verbe=get$q', {});
    if (r['code'] != 200 && owner == null && familyId != null) {
      // Compte parent sans cloud : celui de l'élève.
      r = await _post('/cloud/E/$accountId.awp?verbe=get$q', {});
    }
    if (r['code'] != 200) {
      throw switch (r['code']) {
        403 || 210 => 'Le cloud n\'est pas activé pour ton compte par ton établissement.',
        _ => 'Cloud École Directe indisponible (${explain(r)})',
      };
    }
    final root = EdCloudNode.parse(r['data'], fallbackId: folderId ?? '');
    if (folderId == null) return root;
    // Certains serveurs renvoient tout l'arbre : on retrouve le dossier.
    return root.find(folderId) ?? root;
  }

  /// Tout le cloud d'un coup : chaque sous-dossier pas encore chargé est
  /// demandé (jusqu'à [maxFolders] requêtes, espacées comme sur le site).
  Future<EdCloudNode> cloudAll({String? owner, int maxFolders = 60}) async {
    var budget = maxFolders;
    Future<EdCloudNode> fill(EdCloudNode n) async {
      if (!n.folder) return n;
      var node = n;
      if (!node.loaded && budget > 0) {
        budget--;
        try {
          node = await cloud(folderId: node.id, owner: owner);
        } on EdSessionExpired {
          rethrow;
        } catch (_) {}
      }
      return node.copyWith(children: [for (final c in node.children) await fill(c)]);
    }

    return fill(await cloud(owner: owner));
  }

  /// Espaces de travail (classes, clubs…) : ceux dont tu es membre et
  /// ceux que tu peux rejoindre.
  Future<List<EdWorkspace>> workspaces() async {
    if (accountId == null) return const [];
    final r = await _post('/E/$accountId/espacestravail.awp?verbe=get', {});
    if (r['code'] != 200) throw 'Espaces de travail indisponibles (${explain(r)})';
    final data = r['data'];
    final list = data is List
        ? data
        : (data is Map ? (data['espacesTravail'] ?? data['espaces'] ?? const []) : const []);
    return [
      for (final w in list as List)
        if (w is Map && w['id'] != null) EdWorkspace.fromJson(w.cast<String, dynamic>()),
    ];
  }

  /// Rejoint un espace de travail ouvert.
  Future<void> joinWorkspace(EdWorkspace w) async {
    final r = await _post('/E/$accountId/espacestravail/${w.id}/acces.awp?verbe=post', {
      ...w.raw,
      'cloudLibelle': w.raw['cloudLibelle'] ?? '',
      'fullLoaded': false,
    });
    if (r['code'] != 200) throw 'Impossible de rejoindre cet espace (${explain(r)})';
  }

  /// Documents de l'établissement : bulletins, relevés de notes, vie
  /// scolaire, documents administratifs, factures.
  Future<List<EdDocument>> documents() async {
    final r = await _post(
      familyId != null ? '/familleDocuments.awp?archive=&verbe=get' : '/elevesDocuments.awp?archive=&verbe=get',
      {'forceDownload': 0},
    );
    if (r['code'] != 200 || r['data'] is! Map) {
      if (familyId != null) {
        final r2 = await _post('/elevesDocuments.awp?archive=&verbe=get', {'forceDownload': 0});
        if (r2['code'] == 200) return EdDocument.parse(r2['data']);
      }
      throw 'Documents indisponibles (${explain(r)})';
    }
    return EdDocument.parse(r['data']);
  }

  /// Télécharge un document de l'établissement.
  Future<List<int>> documentFile(EdDocument d) async {
    await _pace();
    final res = await _http
        .post(
          Uri.parse('$_base/telechargement.awp?verbe=get&fichierId=${Uri.encodeQueryComponent(d.id)}&v=$_v'),
          headers: _headers(),
          body: body({'forceDownload': 0}),
        )
        .timeout(const Duration(seconds: 60));
    _keep(res);
    final head = utf8.decode(res.bodyBytes.take(40).toList(), allowMalformed: true).trimLeft();
    if (res.statusCode >= 400 || res.bodyBytes.isEmpty || head.startsWith('{"code"')) {
      throw 'Document indisponible (code ${res.statusCode})';
    }
    return res.bodyBytes;
  }

  /// Télécharge un fichier du cloud.
  Future<List<int>> cloudFile(EdCloudNode f) => attachment(EdAttachment(0, f.name, 'CLOUD'), fileId: f.id);

  /// Répond à l'expéditeur d'un message.
  Future<void> reply(EdMessage original, String text) async {
    final f = original.sender;
    if (f['id'] == null) throw 'Impossible de répondre à ce message';
    final html = '<p>${const HtmlEscape().convert(text).replaceAll('\n', '<br>')}</p>';
    final subject = original.subject.toLowerCase().startsWith('re') ? original.subject : 'RE : ${original.subject}';
    final r = await _post('$_mailbox/messages.awp?verbe=post', {
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
      'anneeMessages': _year,
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
        final seance = m['contenuDeSeance'] is Map ? m['contenuDeSeance'] as Map : todo['contenuDeSeance'];
        out.add(
          EdHomework(
            '${todo['idDevoir'] ?? '$day${m['matiere']}'}',
            DateTime.tryParse(day) ?? DateTime.now(),
            m['matiere'] as String? ?? '',
            decodeContent(todo['contenu'] as String?),
            todo['effectue'] == true,
            m['interrogation'] == true,
            files: homeworkFiles(todo, seance),
            lesson: seance is Map ? decodeContent(seance['contenu'] as String?) : '',
          ),
        );
      }
    }
    return out;
  }

  /// Les fichiers joints à un devoir (et au contenu de la séance) : sujets,
  /// fiches, PDF du prof. Téléchargés avec le type `FICHIER_CDT`.
  static List<EdAttachment> homeworkFiles(Object? todo, Object? seance) {
    final out = <EdAttachment>[];
    final seen = <String>{};
    void add(Object? list) {
      if (list is! List) return;
      for (final f in list) {
        if (f is! Map) continue;
        final id = f['id'] is int ? f['id'] as int : int.tryParse('${f['id']}');
        if (id == null || id == 0) continue;
        final type = '${f['type'] ?? ''}'.trim();
        if (!seen.add('$id')) continue;
        out.add(
          EdAttachment(
            id,
            decodeEntities('${f['libelle'] ?? f['name'] ?? 'fichier'}'),
            type.isEmpty ? 'FICHIER_CDT' : type,
          ),
        );
      }
    }

    if (todo is Map) {
      add(todo['documents']);
      add(todo['ressourceDocuments']);
    }
    if (seance is Map) add(seance['documents']);
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
  EdMessage(
    this.id,
    this.subject,
    this.from,
    this.date,
    this.read, [
    this.sender = const {},
    this.sent = false,
    this.hasFiles = false,
  ]);
  final int id;
  final String subject;

  /// Expéditeur (ou destinataire pour un message envoyé).
  final String from;
  final DateTime? date;
  bool read;

  /// Fiche brute de l'expéditeur (sert à lui répondre).
  final Map<String, dynamic> sender;

  /// Message que tu as envoyé.
  final bool sent;
  final bool hasFiles;

  static String _name(Map f) {
    final n = f['name'];
    if (n is String && n.trim().isNotEmpty) return n.trim();
    return [
      f['civilite'],
      f['prenom'],
      f['nom'],
    ].whereType<String>().where((s) => s.trim().isNotEmpty).join(' ').trim();
  }

  factory EdMessage.fromJson(Map<String, dynamic> j, {bool sent = false}) {
    final f = (j['from'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
    String name;
    if (sent) {
      final to = j['to'];
      final first = to is List && to.isNotEmpty && to.first is Map ? to.first as Map : const {};
      name = _name(first);
      if (to is List && to.length > 1) name = '$name +${to.length - 1}';
      name = name.isEmpty ? '?' : 'À $name';
    } else {
      name = _name(f);
    }
    return EdMessage(
      j['id'] is int ? j['id'] as int : int.tryParse('${j['id']}') ?? 0,
      (j['subject'] as String?)?.trim().isNotEmpty == true
          ? EdClient.decodeEntities((j['subject'] as String).trim())
          : '(sans objet)',
      name.isEmpty ? '?' : EdClient.decodeEntities(name),
      DateTime.tryParse('${j['date'] ?? ''}'.replaceFirst(' ', 'T')),
      sent || j['read'] == true,
      f,
      sent,
      (j['files'] as List?)?.isNotEmpty == true,
    );
  }
}

/// Une pièce jointe d'un message.
class EdAttachment {
  EdAttachment(this.id, this.name, this.type);
  final int id;
  final String name;
  final String type;
}

/// Un fichier ou un dossier du cloud École Directe.
class EdCloudNode {
  EdCloudNode({
    required this.id,
    required this.name,
    required this.folder,
    this.size = 0,
    this.date,
    this.children = const [],
    this.loaded = true,
  });

  /// Chemin donné par École Directe (ex. « \\E\\1234\\Maths\\cours.pdf »).
  final String id;
  final String name;
  final bool folder;
  final int size;
  final DateTime? date;
  final List<EdCloudNode> children;

  /// Contenu déjà envoyé par École Directe (sinon : à demander).
  final bool loaded;

  EdCloudNode copyWith({List<EdCloudNode>? children, String? name}) => EdCloudNode(
    id: id,
    name: name ?? this.name,
    folder: folder,
    size: size,
    date: date,
    children: children ?? this.children,
    loaded: children != null || loaded,
  );

  /// Tous les fichiers, dans tous les sous-dossiers.
  Iterable<EdCloudNode> get allFiles sync* {
    for (final c in children) {
      if (c.folder) {
        yield* c.allFiles;
      } else {
        yield c;
      }
    }
  }

  EdCloudNode? find(String id) {
    if (this.id == id) return this;
    for (final c in children) {
      final f = c.find(id);
      if (f != null) return f;
    }
    return null;
  }

  /// Lit la réponse du serveur : une liste de nœuds (la racine en premier)
  /// ou un seul nœud.
  static EdCloudNode parse(Object? data, {String fallbackId = ''}) {
    if (data is List) {
      final nodes = [
        for (final e in data)
          if (e is Map) EdCloudNode.fromJson(e.cast<String, dynamic>()),
      ];
      if (nodes.length == 1 && nodes.first.folder) return nodes.first;
      return EdCloudNode(id: fallbackId, name: 'Cloud', folder: true, children: nodes);
    }
    if (data is Map) {
      final m = data.cast<String, dynamic>();
      if (m['type'] != null || m['children'] != null) return EdCloudNode.fromJson(m);
      for (final k in ['cloud', 'arborescence', 'items', 'fichiers']) {
        if (m[k] != null) return parse(m[k], fallbackId: fallbackId);
      }
    }
    return EdCloudNode(id: fallbackId, name: 'Cloud', folder: true);
  }

  factory EdCloudNode.fromJson(Map<String, dynamic> j) {
    final type = '${j['type'] ?? ''}'.toLowerCase();
    final kids = j['children'];
    final folder = type == 'folder' || type == 'dossier' || (type.isEmpty && kids is List);
    final id = '${j['id'] ?? j['idFile'] ?? j['libelle'] ?? ''}';
    var name = EdClient.decodeEntities('${j['libelle'] ?? j['name'] ?? ''}').trim();
    if (name.isEmpty || name == '/' || name == '\\') {
      name = id.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty).lastOrNull ?? 'Cloud';
    }
    return EdCloudNode(
      id: id,
      name: name,
      folder: folder,
      size: (j['taille'] as num?)?.toInt() ?? int.tryParse('${j['taille'] ?? ''}') ?? 0,
      date: DateTime.tryParse('${j['date'] ?? ''}'.replaceFirst(' ', 'T')),
      children:
          [
            if (kids is List)
              for (final k in kids)
                if (k is Map) EdCloudNode.fromJson(k.cast<String, dynamic>()),
          ]..sort((a, b) {
            if (a.folder != b.folder) return a.folder ? -1 : 1;
            return a.name.toLowerCase().compareTo(b.name.toLowerCase());
          }),
      loaded: folder ? (j['isLoaded'] != false || (kids is List && kids.isNotEmpty)) : true,
    );
  }
}

/// Un espace de travail École Directe (avec son propre cloud).
class EdWorkspace {
  const EdWorkspace(
    this.id,
    this.title,
    this.hasCloud, {
    this.description = '',
    this.members = 0,
    this.member = true,
    this.createdBy = '',
    this.discussion = false,
    this.agenda = false,
    this.raw = const {},
  });

  factory EdWorkspace.fromJson(Map<String, dynamic> w) => EdWorkspace(
    '${w['id']}',
    EdClient.decodeEntities('${w['titre'] ?? w['libelle'] ?? 'Espace de travail'}').trim(),
    w['cloud'] != false,
    description: EdClient.decodeContent('${w['description'] ?? w['resume'] ?? ''}'),
    members: (w['nbMembres'] as num?)?.toInt() ?? 0,
    member: w['estMembre'] != false,
    createdBy: EdClient.decodeEntities('${w['creePar'] ?? ''}').trim(),
    discussion: w['discussion'] == true,
    agenda: w['agenda'] == true,
    raw: w,
  );

  final String id;
  final String title;
  final bool hasCloud;
  final String description;
  final int members;
  final bool member;
  final String createdBy;
  final bool discussion;
  final bool agenda;
  final Map<String, dynamic> raw;
}

/// Un document de l'établissement (bulletin, relevé, certificat…).
class EdDocument {
  const EdDocument({required this.id, required this.title, required this.category, this.date});
  final String id;
  final String title;
  final String category;
  final DateTime? date;

  static const categories = {
    'notes': 'Notes et bulletins',
    'viescolaire': 'Vie scolaire',
    'administratifs': 'Documents administratifs',
    'inscriptions': 'Inscriptions',
    'factures': 'Factures',
    'entreprises': 'Stages',
    'listesPiecesAVerser': 'Pièces à fournir',
  };

  static List<EdDocument> parse(Object? data) {
    if (data is! Map) return const [];
    final out = <EdDocument>[];
    for (final e in data.entries) {
      final list = e.value;
      if (list is! List) continue;
      for (final d in list) {
        if (d is! Map || d['id'] == null) continue;
        out.add(
          EdDocument(
            id: '${d['id']}',
            title: EdClient.decodeEntities('${d['libelle'] ?? d['titre'] ?? 'Document'}').trim(),
            category: categories['${e.key}'] ?? '${e.key}',
            date: DateTime.tryParse('${d['date'] ?? ''}'.replaceFirst(' ', 'T')),
          ),
        );
      }
    }
    out.sort((a, b) => (b.date ?? DateTime(0)).compareTo(a.date ?? DateTime(0)));
    return out;
  }
}

/// Contenu d'un message École Directe.
class EdMessageContent {
  EdMessageContent(this.text, this.files);
  final String text;
  final List<EdAttachment> files;

  factory EdMessageContent.fromJson(Map<String, dynamic> d) {
    // Le contenu est en base64 (HTML), parfois coupé en lignes ; certains
    // établissements renvoient directement le HTML.
    return EdMessageContent(EdClient.decodeContent('${d['content'] ?? ''}'), [
      for (final f in (d['files'] as List?) ?? const [])
        if (f is Map)
          EdAttachment(
            f['id'] is int ? f['id'] as int : int.tryParse('${f['id']}') ?? 0,
            EdClient.decodeEntities('${f['libelle'] ?? f['name'] ?? 'pièce jointe'}'),
            '${f['type'] ?? 'PIECE_JOINTE'}',
          ),
    ]);
  }
}

class EdHomework {
  EdHomework(
    this.id,
    this.due,
    this.subject,
    this.content,
    this.done,
    this.isTest, {
    this.files = const [],
    this.lesson = '',
  });
  final String id;
  final DateTime due;
  final String subject;
  final String content;
  final bool done;
  final bool isTest;

  /// Fichiers joints par le prof (PDF, sujets, fiches…).
  final List<EdAttachment> files;

  /// Ce qui a été fait en classe (contenu de séance), s'il est donné.
  final String lesson;
}

class EdGrade {
  EdGrade(
    this.id,
    this.subject,
    this.value,
    this.outOf,
    this.title,
    this.date, {
    this.coef = 1,
    this.period = '',
    this.counts = true,
  });
  final String id;
  final String subject;
  final String value;
  final String outOf;
  final String title;
  final DateTime? date;

  /// Coefficient de la note (1 si École Directe ne le donne pas).
  final double coef;

  /// Période (trimestre / semestre) : « A001 »…
  final String period;

  /// Compte dans la moyenne (pas « non significative », pas en lettres).
  final bool counts;

  static double _num(Object? v, double fallback) =>
      double.tryParse('${v ?? ''}'.trim().replaceAll(',', '.')) ?? fallback;

  factory EdGrade.fromJson(Map<String, dynamic> j) => EdGrade(
    '${j['id']}',
    j['libelleMatiere'] as String? ?? '',
    '${j['valeur'] ?? ''}'.trim(),
    '${j['noteSur'] ?? '20'}'.trim(),
    j['devoir'] as String? ?? '',
    DateTime.tryParse(j['date'] as String? ?? ''),
    coef: _num(j['coef'], 1),
    period: '${j['codePeriode'] ?? ''}',
    counts: j['nonSignificatif'] != true && j['enLettre'] != true,
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
    this.kind = 'COURS',
    this.exempt = false,
    this.changed = false,
  ]);
  final String subject;
  final DateTime start;
  final DateTime end;
  final String room;
  final String teacher;
  final bool cancelled;

  /// Couleur de la matière choisie par l'établissement (#rrggbb).
  final String? color;

  /// Le type École Directe : COURS, PERMANENCE, CONGE, EVENEMENT…
  final String kind;

  /// Tu es dispensé de ce cours (sport…).
  final bool exempt;

  /// Cours modifié (salle, horaire, prof remplaçant).
  final bool changed;

  /// Un congé (vacances, pont, férié) affiché dans l'emploi du temps, pas un
  /// cours : Nexo ne doit jamais le prendre pour « ton prochain cours ».
  bool get isBreak =>
      kind.toUpperCase().contains('CONGE') ||
      RegExp(r'^(?:cong[ée]s?|vacances|f[ée]ri[ée])\b|\bvacances\b', caseSensitive: false).hasMatch(subject);

  static bool _yes(Object? v) => v == true || v == 1 || '$v' == '1' || '$v'.toLowerCase() == 'true';

  factory EdLesson.fromJson(Map<String, dynamic> j) => EdLesson(
    (j['matiere'] as String?)?.isNotEmpty == true ? j['matiere'] as String : (j['text'] as String? ?? 'Cours'),
    DateTime.parse((j['start_date'] as String).replaceFirst(' ', 'T')),
    DateTime.parse((j['end_date'] as String).replaceFirst(' ', 'T')),
    j['salle'] as String? ?? '',
    j['prof'] as String? ?? '',
    j['isAnnule'] == true,
    j['color'] as String?,
    '${j['typeCours'] ?? 'COURS'}',
    _yes(j['dispense']),
    j['isModifie'] == true,
  );
}
