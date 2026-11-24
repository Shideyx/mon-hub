import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/account_sync.dart';
import 'package:hub/core/module_store.dart';
import 'package:hub/core/session.dart';
import 'package:hub/web/account_copy.dart';
import 'package:hub/web/phone_actions.dart';
import 'package:hub/web/web_smily.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final contacts = {'Maman': '0612345678', 'Léo': '+33698765432'};

  group('PhoneRules : numéros et contacts', () {
    test('numéros', () {
      expect(PhoneRules.number('06 12 34 56 78'), '0612345678');
      expect(PhoneRules.number('+33 6 12-34-56-78'), '+33612345678');
      expect(PhoneRules.number('maman'), isNull);
      expect(PhoneRules.number('12'), isNull);
    });

    test('contacts : « ma mère » = maman, accents ignorés', () {
      expect(PhoneRules.who('ma mère', contacts), ('Maman', '0612345678'));
      expect(PhoneRules.who('leo', contacts), ('Léo', '+33698765432'));
      expect(PhoneRules.who('Paul', contacts), isNull);
      expect(PhoneRules.who('0611223344', contacts), ('0611223344', '0611223344'));
    });
  });

  group('PhoneRules.parse : phrases reconnues sans IA', () {
    test('appeler', () {
      final a = PhoneRules.parse('Appelle maman', contacts)!;
      expect(a.kind, 'appel');
      expect(a.url, 'tel:0612345678');
      expect(PhoneRules.parse('appelle Paul', contacts)!.kind, 'contact?');
    });

    test('retenir un numéro', () {
      final a = PhoneRules.parse("Le numéro de Mamie c'est 06 11 22 33 44", contacts)!;
      expect(a.kind, 'contact');
      expect(a.contact, ('Mamie', '0611223344'));
      expect(a.immediate, isTrue);
    });

    test('SMS préparé (jamais envoyé tout seul)', () {
      final a = PhoneRules.parse('Envoie un message à Léo pour lui dire que j\'arrive dans 5 min', contacts)!;
      expect(a.kind, 'sms');
      expect(a.url, startsWith('sms:+33698765432&body='));
      expect(Uri.decodeComponent(a.url!.split('body=').last), 'J\'arrive dans 5 min');
      expect(a.immediate, isFalse);
      final b = PhoneRules.parse('écris à maman : je rentre', contacts)!;
      expect(Uri.decodeComponent(b.url!.split('body=').last), 'Je rentre');
    });

    test('itinéraire, raccourci, appli, musique, recherche', () {
      expect(PhoneRules.parse('Itinéraire vers la gare de Lyon', contacts)!.url,
          'https://maps.apple.com/?daddr=la%20gare%20de%20Lyon');
      expect(PhoneRules.parse('lance le raccourci Mode nuit', contacts)!.url,
          'shortcuts://run-shortcut?name=Mode%20nuit');
      expect(PhoneRules.parse('Ouvre Snapchat', contacts)!.url, 'snapchat://');
      final m = PhoneRules.parse('Mets du Jul', contacts)!;
      expect(m.kind, 'musique');
      expect(m.url, 'spotify:search:Jul');
      expect(m.fallbackUrl, 'https://open.spotify.com/search/Jul');
      expect(PhoneRules.parse('cherche horaires piscine', contacts)!.kind, 'recherche');
    });

    test('minuteur et rappels', () {
      final t = PhoneRules.parse('Minuteur 10 min pour les pâtes', contacts)!;
      expect(t.kind, 'minuteur');
      expect(t.timer, const Duration(minutes: 10));
      expect(t.timerFor, 'pâtes');
      expect(PhoneRules.parse('mets un minuteur de 1 h 30', contacts)!.timer, const Duration(minutes: 90));
      final r = PhoneRules.parse('Rappelle-moi de sortir le chien dans 20 min', contacts)!;
      expect(r.kind, 'minuteur');
      expect(r.timerFor, 'Sortir le chien');
      final now = DateTime(2026, 11, 24, 9, 0); // mardi
      final e = PhoneRules.parse('Rappelle-moi de réviser demain à 18 h', contacts, now: now)!;
      expect(e.kind, 'agenda');
      expect(e.ics, contains('SUMMARY:Réviser'));
      expect(e.ics, contains('DTSTART:${_utc(DateTime(2026, 11, 25, 18))}'));
      expect(e.ics, contains('BEGIN:VALARM'));
    });

    test('les vraies questions partent vers l\'IA', () {
      for (final q in [
        'Pourquoi le ciel est bleu ?',
        'Explique-moi le théorème de Pythagore',
        'Mets-toi à ma place',
        'Tu peux m\'aider pour mon exposé ?',
      ]) {
        expect(PhoneRules.parse(q, contacts), isNull, reason: q);
      }
    });
  });

  group('dates et durées', () {
    test('durées', () {
      expect(PhoneRules.duration('10 min'), const Duration(minutes: 10));
      expect(PhoneRules.duration('une heure'), const Duration(hours: 1));
      expect(PhoneRules.duration('45 secondes'), const Duration(seconds: 45));
      expect(PhoneRules.duration('2h15'), const Duration(hours: 2, minutes: 15));
      expect(PhoneRules.duration('bientôt'), isNull);
    });

    test('quand', () {
      final now = DateTime(2026, 11, 24, 9, 0); // mardi
      expect(PhoneRules.when('à 8 h', now), DateTime(2026, 11, 25, 8)); // passé → demain
      expect(PhoneRules.when('à 17h30', now), DateTime(2026, 11, 24, 17, 30));
      expect(PhoneRules.when('lundi à 9 h', now), DateTime(2026, 11, 30, 9));
      expect(PhoneRules.when('ce soir', now), DateTime(2026, 11, 24, 19));
      expect(PhoneRules.sayWhen(DateTime(2026, 11, 25, 18), now), 'demain à 18 h');
    });
  });

  group('Gemini : fonctions → boutons', () {
    test('fromTool', () {
      expect(PhoneRules.fromTool('telephone_appeler', {'qui': 'maman'}, contacts)!.url, 'tel:0612345678');
      expect(PhoneRules.fromTool('telephone_minuteur', {'minutes': 5}, contacts)!.timer, const Duration(minutes: 5));
      expect(PhoneRules.fromTool('telephone_minuteur', {'minutes': -1}, contacts), isNull);
      final ag = PhoneRules.fromTool('telephone_agenda', {'titre': 'Dentiste', 'debut': '2026-12-01T14:30'}, contacts)!;
      expect(ag.ics, contains('SUMMARY:Dentiste'));
      String? kept;
      expect(PhoneRules.fromTool('memoire_retenir', {'texte': 'Aime le foot'}, contacts, remembered: (t) => kept = t),
          isNull);
      expect(kept, 'Aime le foot');
      final names = [for (final t in PhoneRules.tools) t['name']];
      expect(names.toSet().length, names.length);
    });

    test('Nexo web : règles d\'abord, puis Gemini avec ses fonctions', () async {
      SharedPreferences.setMockInitialValues({});
      await ModuleStore.init();
      final s = WebSmily.instance;
      s.contacts = {...contacts};
      Map<String, Object?>? sent;
      WebSmily.geminiOverride = (body) async {
        sent = body;
        return {
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'Je te prépare ça !'},
                  {
                    'functionCall': {
                      'name': 'telephone_sms',
                      'args': {'qui': 'maman', 'texte': 'Je serai en retard'},
                    },
                  },
                ],
              },
            },
          ],
        };
      };
      addTearDown(() => WebSmily.geminiOverride = null);
      final rule = await s.answer('Appelle maman');
      expect(sent, isNull);
      expect(rule.actions.single.url, 'tel:0612345678');
      final r = await s.answer('Préviens ma mère que je serai en retard');
      expect(sent, isNotNull);
      expect(jsonEncode(sent), contains('telephone_sms'));
      expect(r.text, 'Je te prépare ça !');
      expect(r.actions.single.kind, 'sms');
      final remembered = await s.answer('Retiens que je fais du basket');
      expect(remembered.text, contains('retenu'));
      expect(s.memories.last.$2, 'Je fais du basket');
    });
  });

  group('lien du PC (QR code)', () {
    test('aller-retour et taille limitée', () {
      final code = PhoneLinkCode(
        name: 'Erik',
        gemini: 'AIzaTEST',
        serverUrl: 'https://abc.supabase.co',
        serverKey: 'a.b.c',
        memories: [for (var i = 0; i < 40; i++) ('gouts', 'Souvenir numéro $i assez long pour remplir le code ' * 2)],
      );
      final link = code.link('https://shideyx.github.io/mon-hub/');
      expect(link, startsWith('https://shideyx.github.io/mon-hub/#lien='));
      expect(code.encode().length, lessThanOrEqualTo(PhoneLinkCode.maxLength));
      final back = PhoneLinkCode.decode(link)!;
      expect(back.name, 'Erik');
      expect(back.gemini, 'AIzaTEST');
      expect(back.serverUrl, 'https://abc.supabase.co');
      expect(back.memories, isNotEmpty);
      expect(back.memories.length, lessThan(40));
      expect(PhoneLinkCode.decode(code.encode())!.name, 'Erik');
      expect(PhoneLinkCode.decode('n\'importe quoi'), isNull);
      expect(PhoneLinkCode.siteFor('Shideyx/mon-hub'), 'https://shideyx.github.io/mon-hub/');
    });
  });

  group('copie du compte lue par la version web', () {
    test('même format que la synchro du PC', () async {
      SyncKey.defaultIterations = 1000;
      addTearDown(() => SyncKey.defaultIterations = 210000);
      const salt = 'sel-du-compte';
      final hash = AccountCopy.passwordHash(salt, 'motdepasse');
      expect(hash, AppSession.passwordHash(salt, 'motdepasse'));
      final acc = HubAccount('erik', 'Erik', 'p.erik.', salt, hash);
      final key = await SyncKey.forAccount(acc);
      final text = await SyncBox.seal(
        login: 'erik',
        account: acc,
        key: key,
        entries: {
          'p:hub.name': SyncEntry('Erik', 1),
          's:mod.claude.gemini.key': SyncEntry('AIzaCLE', 1),
          'f:memoire.json': SyncEntry(
            jsonEncode({
              'souvenirs': [
                {'id': '1', 's': 'gouts', 't': 'Aime le rap', 'w': 3},
                {'id': '2', 's': 'moi', 't': 'S\'appelle Erik', 'p': true},
              ],
            }),
            1,
          ),
        },
      );
      final c = await AccountCopy.open(text, 'motdepasse');
      expect(c['p:hub.name'], 'Erik');
      expect(c['s:mod.claude.gemini.key'], 'AIzaCLE');
      final mem = AccountCopy.memories(c);
      expect(mem.first, ('moi', 'S\'appelle Erik'));
      expect(mem.length, 2);
      expect(() => AccountCopy.open(text, 'mauvais'), throwsA(contains('mot de passe')));
    });
  });
}

String _utc(DateTime d) {
  final u = d.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${u.year}${two(u.month)}${two(u.day)}T${two(u.hour)}${two(u.minute)}00Z';
}
