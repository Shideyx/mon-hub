import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hub/modules/ecoledirecte/ed_client.dart';
import 'package:hub/modules/schedule/schedule_module.dart';

void main() {
  test('évènement perso hebdomadaire', () {
    final e = PersonalEvent(
      id: '1',
      title: 'Foot',
      start: DateTime(2026, 11, 4, 18),
      end: DateTime(2026, 11, 4, 19, 30),
      weekly: true,
    );
    final occ = e.occurrences(DateTime(2026, 11, 16), DateTime(2026, 11, 30)).toList();
    expect(occ.map((o) => o.$1), [DateTime(2026, 11, 18, 18), DateTime(2026, 11, 25, 18)]);
    expect(occ.first.$2, DateTime(2026, 11, 18, 19, 30));
    final once = PersonalEvent.fromJson({...e.toJson(), 'weekly': false});
    expect(once.occurrences(DateTime(2026, 11, 16), DateTime(2026, 11, 30)), isEmpty);
  });

  test('connexion École Directe avec question de sécurité (comme le vrai serveur)', () async {
    // Le serveur lit le corps comme un formulaire : un « + » non encodé y
    // devient un espace. Les réponses en base64 en contiennent souvent.
    const answer = 'MjAxMSA+Pj4='; // « 2011 >>> »
    const cn = 'Q04+cXc='; // contient un « + »
    const cv = 'Y3YrK3Y=';
    final log = <String>[];
    var gtkCount = 0;
    final client = MockClient((req) async {
      Map<String, dynamic> data() =>
          jsonDecode(Uri.splitQueryString(req.body)['data']!) as Map<String, dynamic>;
      final h = {for (final e in req.headers.entries) e.key.toLowerCase(): e.value};
      if (req.method == 'GET') {
        gtkCount++;
        log.add('gtk');
        return http.Response(
          '',
          200,
          headers: {
            'set-cookie': 'GTK=gtk$gtkCount; Path=/,other=1; expires=Wed, 21 Oct 2026 07:28:00 GMT',
          },
        );
      }
      if (req.url.path.endsWith('login.awp')) {
        final d = data();
        expect(h['x-gtk'], 'gtk$gtkCount', reason: 'GTK frais avant chaque connexion');
        expect(h['cookie'], contains('GTK=gtk$gtkCount'));
        expect(d['motdepasse'], 'p@ss&+ é', reason: 'mot de passe intact');
        if ((d['fa'] as List).isEmpty) {
          log.add('login');
          return http.Response(
            '{"code":250,"token":"tmp","message":"","data":{}}',
            200,
            headers: {'2fa-token': 'f2a', 'x-token': 'tmp'},
          );
        }
        log.add('login-final');
        // Comme le site : cn/cv en haut ET dans fa, avec les deux jetons.
        expect(d['cn'], cn);
        expect(d['cv'], cv);
        expect((d['fa'] as List).single, {'cn': cn, 'cv': cv, 'uniq': false});
        expect(h['x-token'], 'tmp2');
        expect(h['2fa-token'], 'f2a');
        return http.Response(
          jsonEncode({
            'code': 200,
            'token': 'final',
            'data': {
              'accounts': [
                {'id': 42, 'prenom': 'Erik', 'nom': 'M', 'typeCompte': 'E'},
              ],
            },
          }),
          200,
        );
      }
      if (req.url.queryParameters['verbe'] == 'get') {
        log.add('question');
        expect(h['x-token'], 'tmp');
        expect(h['2fa-token'], 'f2a');
        expect(h.containsKey('x-gtk'), isFalse);
        return http.Response(
          jsonEncode({
            'code': 200,
            'data': {
              'question': base64.encode(utf8.encode('Année ?')),
              'propositions': [base64.encode(utf8.encode('2010')), answer],
            },
          }),
          200,
        );
      }
      log.add('réponse');
      expect(data()['choix'], answer, reason: 'la réponse arrive intacte (avec son « + »)');
      return http.Response(
        jsonEncode({
          'code': 200,
          'token': 'tmp2',
          'data': {'cn': cn, 'cv': cv},
        }),
        200,
      );
    });
    final ed = EdClient(client, false);
    await ed.login(
      'erik',
      'p@ss&+ é',
      answerQuestion: (q, c) async {
        expect(q, 'Année ?');
        expect(c, ['2010', '2011 >>>']);
        return c.last;
      },
    );
    expect(log, ['gtk', 'login', 'question', 'réponse', 'gtk', 'login-final']);
    expect(ed.accountId, 42);
    expect(ed.token, 'final');
    expect(ed.lastFa, [
      {'cn': cn, 'cv': cv},
    ]);
  });

  test('facteurs gardés refusés : on recommence sans eux', () async {
    var logins = 0;
    final client = MockClient((req) async {
      if (req.method == 'GET') return http.Response('', 200, headers: {'set-cookie': 'GTK=g'});
      final d = jsonDecode(Uri.splitQueryString(req.body)['data']!) as Map<String, dynamic>;
      logins++;
      if ((d['fa'] as List).isNotEmpty) return http.Response('{"code":505,"message":"x"}', 200);
      return http.Response(
        jsonEncode({
          'code': 200,
          'data': {
            'accounts': [
              {'id': 7, 'prenom': 'A', 'nom': 'B', 'typeCompte': 'E'},
            ],
          },
        }),
        200,
      );
    });
    final ed = EdClient(client, false);
    await ed.login(
      'a',
      'b',
      answerQuestion: (_, _) async => null,
      savedFa: [
        {'cn': 'old', 'cv': 'old'},
      ],
    );
    expect(logins, 2);
    expect(ed.accountId, 7);
  });

  test('École Directe : mot de passe refusé = arrêt, session expirée = signalée', () async {
    var calls = 0;
    final refuse = MockClient((req) async {
      calls++;
      if (req.method == 'GET') return http.Response('{}', 200);
      expect(req.headers['Origin'] ?? req.headers['origin'], 'https://www.ecoledirecte.com');
      return http.Response(jsonEncode({'code': 505, 'message': 'Mot de passe invalide'}), 200);
    });
    final ed = EdClient(refuse, false);
    await expectLater(
      ed.login('a', 'b', answerQuestion: (_, _) async => null),
      throwsA(isA<EdAuthError>()),
    );
    expect(calls, 2, reason: 'une seule tentative de connexion, pas de boucle');

    final expired = MockClient(
      (req) async => http.Response(jsonEncode({'code': 525, 'message': ''}), 200),
    );
    final ed2 = EdClient(expired, false)
      ..token = 'vieux'
      ..accountId = 1;
    await expectLater(ed2.grades(), throwsA(isA<EdSessionExpired>()));
  });
}
