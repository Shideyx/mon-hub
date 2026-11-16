import 'dart:convert';

import 'package:http/http.dart' as http;

/// Client pour l'API **non officielle** d'École Directe (celle qu'utilise
/// leur propre site). Elle n'est pas documentée et change de temps en temps :
/// si la connexion casse après une mise à jour d'École Directe, c'est ici
/// qu'il faut corriger.
class EdClient {
  EdClient([http.Client? client]) : _http = client ?? http.Client();

  static const _base = 'https://api.ecoledirecte.com/v3';
  static const _v = '4.90.1';
  final http.Client _http;

  String? token;
  int? accountId;
  String? studentName;
  String? _gtk;

  Map<String, String> get _headers => {
        'Content-Type': 'application/x-www-form-urlencoded',
        'User-Agent': 'Mozilla/5.0 (HubApp)',
        'X-Gtk': ?_gtk,
        if (_gtk != null) 'Cookie': 'GTK=$_gtk',
        'X-Token': ?token,
      };

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> data) async {
    final sep = path.contains('?') ? '&' : '?';
    final res = await _http.post(
      Uri.parse('$_base$path${sep}v=$_v'),
      headers: _headers,
      body: 'data=${jsonEncode(data)}',
    );
    final newToken = res.headers['x-token'];
    if (newToken != null && newToken.isNotEmpty) token = newToken;
    return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  }

  /// Connexion. [answerQuestion] est appelé si École Directe pose sa
  /// question de sécurité (double authentification) : il reçoit la question
  /// et les choix, et doit renvoyer le choix sélectionné.
  Future<void> login(
    String user,
    String password, {
    required Future<String?> Function(String question, List<String> choices)
        answerQuestion,
    List<Map<String, String>>? savedFa,
  }) async {
    // 1. Cookie GTK exigé depuis 2024.
    final g = await _http.get(Uri.parse('$_base/login.awp?gtk=1&v=$_v'),
        headers: {'User-Agent': 'Mozilla/5.0 (HubApp)'});
    final cookie = g.headers['set-cookie'] ?? '';
    _gtk = RegExp(r'GTK=([^;]+)').firstMatch(cookie)?.group(1);

    Future<Map<String, dynamic>> doLogin(List<Map<String, String>> fa) => _post(
          '/login.awp',
          {
            'identifiant': Uri.encodeComponent(user),
            'motdepasse': Uri.encodeComponent(password),
            'isRelogin': false,
            'uuid': '',
            'fa': fa,
          },
        );

    var r = await doLogin(savedFa ?? []);
    if (r['code'] == 250) {
      // 2. Question de sécurité (ex. « Quelle est ton année de naissance ? »).
      final q = await _post('/connexion/doubleauth.awp?verbe=get', {});
      final d = q['data'] as Map<String, dynamic>;
      String b64(String s) => utf8.decode(base64.decode(s));
      final question = b64(d['question'] as String);
      final choices = (d['propositions'] as List).cast<String>();
      final picked = await answerQuestion(question, choices.map(b64).toList());
      if (picked == null) throw 'Connexion annulée';
      final enc = choices[choices.map(b64).toList().indexOf(picked)];
      final a = await _post('/connexion/doubleauth.awp?verbe=post', {'choix': enc});
      final ad = a['data'] as Map<String, dynamic>;
      lastFa = [
        {'cn': ad['cn'] as String, 'cv': ad['cv'] as String}
      ];
      r = await doLogin(lastFa!);
    }
    if (r['code'] != 200) {
      throw r['message']?.toString().isNotEmpty == true
          ? r['message'].toString()
          : 'Échec de connexion (code ${r['code']})';
    }
    token = r['token'] as String? ?? token;
    final acc = ((r['data'] as Map)['accounts'] as List).first as Map;
    accountId = acc['id'] as int;
    studentName = '${acc['prenom']} ${acc['nom']}';
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

  Future<List<EdLesson>> timetable(DateTime from, DateTime to) async {
    String d(DateTime x) => x.toIso8601String().substring(0, 10);
    final r = await _post('/E/$accountId/emploidutemps.awp?verbe=get',
        {'dateDebut': d(from), 'dateFin': d(to), 'avecTrous': false});
    if (r['code'] != 200) throw 'Emploi du temps indisponible (code ${r['code']})';
    return (r['data'] as List)
        .map((e) => EdLesson.fromJson(e as Map<String, dynamic>))
        .toList()
      ..sort((a, b) => a.start.compareTo(b.start));
  }
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
  EdLesson(this.subject, this.start, this.end, this.room, this.teacher, this.cancelled);
  final String subject;
  final DateTime start;
  final DateTime end;
  final String room;
  final String teacher;
  final bool cancelled;

  factory EdLesson.fromJson(Map<String, dynamic> j) => EdLesson(
        (j['matiere'] as String?)?.isNotEmpty == true
            ? j['matiere'] as String
            : (j['text'] as String? ?? 'Cours'),
        DateTime.parse((j['start_date'] as String).replaceFirst(' ', 'T')),
        DateTime.parse((j['end_date'] as String).replaceFirst(' ', 'T')),
        j['salle'] as String? ?? '',
        j['prof'] as String? ?? '',
        j['isAnnule'] == true,
      );
}
