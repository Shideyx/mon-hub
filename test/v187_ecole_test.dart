import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/module_store.dart';
import 'package:hub/core/hub_feed.dart';
import 'package:hub/core/school_calendar.dart';
import 'package:hub/ui/clicky/autonomy.dart';
import 'package:hub/ui/clicky/quick.dart';
import 'package:hub/ui/clicky/robots.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, Object?> lesson(String t, DateTime s, int minutes, {bool off = false, bool conge = false}) => {
  'titre': t,
  'debut': s,
  'fin': s.add(Duration(minutes: minutes)),
  'source': 'École Directe',
  if (off) 'annule': true,
  if (conge) 'vacances': true,
};

/// Une journée type : 8 h – 12 h, midi, 13 h 30 – 16 h 30.
List<Map> day(DateTime d, {Set<String> off = const {}}) {
  DateTime at(int h, [int m = 0]) => DateTime(d.year, d.month, d.day, h, m);
  return [
    lesson('MATHS', at(8), 60, off: off.contains('MATHS')),
    lesson('FRANCAIS', at(9), 60, off: off.contains('FRANCAIS')),
    lesson('SVT', at(10), 60, off: off.contains('SVT')),
    lesson('ANGLAIS', at(11), 60, off: off.contains('ANGLAIS')),
    lesson('HISTOIRE', at(13, 30), 60, off: off.contains('HISTOIRE')),
    lesson('EPS', at(14, 30), 120, off: off.contains('EPS')),
  ];
}

void main() {
  group('Jours fériés (calculés, sans internet)', () {
    test('Pâques et les fêtes qui en dépendent', () {
      expect(SchoolRules.easter(2026), DateTime(2026, 4, 5));
      expect(SchoolRules.easter(2027), DateTime(2027, 3, 28));
      expect(SchoolRules.easter(2024), DateTime(2024, 3, 31));
      final f = SchoolRules.publicHolidays(2027);
      expect(f[DateTime(2027, 3, 29)], 'Lundi de Pâques');
      expect(f[DateTime(2027, 5, 6)], 'Ascension');
      expect(f[DateTime(2027, 5, 17)], 'Lundi de Pentecôte');
      expect(SchoolRules.publicHoliday(DateTime(2026, 11, 11, 15)), 'Armistice');
      expect(SchoolRules.publicHoliday(DateTime(2026, 11, 12)), isNull);
    });

    test('le prochain jour férié', () {
      final (d, name) = SchoolRules.nextPublicHoliday(DateTime(2026, 11, 25));
      expect(d, DateTime(2026, 12, 25));
      expect(name, 'Noël');
    });
  });

  group('La zone de vacances', () {
    test('d\'après le code postal, la région ou une phrase', () {
      expect(SchoolRules.zoneFromPostcode('69003'), 'A');
      expect(SchoolRules.zoneFromPostcode('75011'), 'C');
      expect(SchoolRules.zoneFromPostcode('59000'), 'B');
      expect(SchoolRules.zoneFromPostcode('20000'), 'Corse');
      expect(SchoolRules.zoneFromPostcode('97400'), 'Réunion');
      expect(SchoolRules.zoneFromRegion('Auvergne-Rhône-Alpes'), 'A');
      expect(SchoolRules.zoneFromRegion('Île-de-France'), 'C');
      expect(SchoolRules.zoneFromRegion('Hauts-de-France'), 'B');
      expect(SchoolRules.zoneFromText('je suis en zone b'), 'B');
      expect(SchoolRules.zoneFromText('C'), 'C');
      expect(SchoolRules.zoneFromText('la a'), 'A');
      expect(SchoolRules.zoneFromText('j\'habite en Corse'), 'Corse');
      expect(SchoolRules.zoneFromText('quelle heure est-il'), isNull);
    });

    test('d\'après le lieu trouvé pour la météo', () {
      expect(
        SchoolRules.zoneFromPlace({
          'country_code': 'FR',
          'postcodes': ['33000'],
          'admin1': 'Nouvelle-Aquitaine',
        }),
        'A',
      );
      expect(SchoolRules.zoneFromPlace({'country_code': 'FR', 'admin1': 'Occitanie'}), 'C');
      expect(SchoolRules.zoneFromPlace({'country_code': 'BE', 'admin1': 'Bruxelles'}), isNull);
    });
  });

  group('Les vacances', () {
    test('la table 2026-2027 rangée dans Mon Hub', () {
      final a = SchoolRules.builtIn('A');
      final noel = SchoolRules.breakOn(DateTime(2026, 12, 25), a)!;
      expect(noel.name, 'Vacances de Noël');
      expect(noel.end, DateTime(2027, 1, 4));
      expect(SchoolRules.breakOn(DateTime(2027, 2, 15), a)!.name, 'Vacances d\'hiver');
      expect(SchoolRules.breakOn(DateTime(2027, 2, 25), SchoolRules.builtIn('C')), isNull);
      expect(SchoolRules.breakOn(DateTime(2027, 2, 25), a), isNotNull);
      expect(SchoolRules.breakOn(DateTime(2027, 2, 8), SchoolRules.builtIn('C'))!.name, 'Vacances d\'hiver');
      // Sans zone : seulement ce qui est commun à toute la France.
      expect(SchoolRules.breakOn(DateTime(2027, 2, 15), SchoolRules.builtIn(null)), isNull);
      expect(SchoolRules.breakOn(DateTime(2026, 12, 28), SchoolRules.builtIn(null)), isNotNull);
      // La reprise est exclue.
      expect(SchoolRules.breakOn(DateTime(2027, 1, 4), a), isNull);
    });

    test('le calendrier officiel (data.education.gouv.fr)', () {
      final list = SchoolRules.parseOfficial({
        'results': [
          {
            'description': 'Vacances de Noël',
            'population': '-',
            'start_date': '2026-12-18T23:00:00+00:00',
            'end_date': '2027-01-03T23:00:00+00:00',
            'zones': 'Zone A',
          },
          // Le même, pour une autre académie : pas de doublon.
          {
            'description': 'Vacances de Noël',
            'population': '-',
            'start_date': '2026-12-18T23:00:00+00:00',
            'end_date': '2027-01-03T23:00:00+00:00',
            'zones': 'Zone A',
          },
          {
            'description': 'Pré-rentrée des enseignants',
            'population': 'Enseignants',
            'start_date': '2026-08-30T22:00:00+00:00',
          },
          {
            'description': 'Rentrée scolaire des élèves',
            'population': 'Élèves',
            'start_date': '2026-08-31T22:00:00+00:00',
          },
          {'description': 'Début des Vacances d\'Été', 'population': '-', 'start_date': '2027-07-02T22:00:00+00:00'},
        ],
      });
      expect(list, hasLength(2));
      expect(list.first.start, DateTime(2026, 12, 19));
      expect(list.first.end, DateTime(2027, 1, 4));
      expect(list.first.source, 'officiel');
      expect(list.last.name, 'Vacances d\'Été');
      expect(list.last.start, DateTime(2027, 7, 3));
      expect(list.last.approxEnd, isTrue);
    });

    test('les congés vus dans École Directe, regroupés', () {
      final ed = [
        for (var i = 0; i < 5; i++) lesson('CONGES', DateTime(2026, 12, 21 + i), 23 * 60 + 59, conge: true),
        lesson('CONGES', DateTime(2026, 12, 28), 23 * 60 + 59, conge: true),
      ];
      final b = SchoolRules.fromAgenda(ed);
      expect(b, hasLength(1));
      expect(b.first.start, DateTime(2026, 12, 21));
      expect(b.first.end, DateTime(2026, 12, 29));
      expect(b.first.source, 'ecole');
      // Fusionné avec l'officiel : le vrai nom et la vraie reprise.
      final m = SchoolRules.merge(b, const [], SchoolRules.builtIn('B'));
      expect(m.where((x) => x.covers(DateTime(2026, 12, 25))), hasLength(1));
      expect(SchoolRules.breakOn(DateTime(2026, 12, 25), m)!.end, DateTime(2027, 1, 4));
    });

    test('un titre « CONGÉS » d\'École Directe n\'est jamais un cours', () {
      final e = {'titre': 'CONGÉS', 'debut': DateTime(2026, 12, 21), 'source': 'École Directe'};
      expect(SchoolRules.isBreakItem(e), isTrue);
      expect(SchoolRules.isLesson(e), isFalse);
      expect(SchoolRules.isLesson(lesson('MATHS', DateTime(2026, 12, 21, 8), 60)), isTrue);
      expect(SchoolRules.isLesson({...lesson('EPS', DateTime(2026, 12, 21, 8), 60), 'dispense': true}), isFalse);
      expect(
        SchoolRules.isLesson({'titre': 'Dentiste', 'debut': DateTime(2026, 12, 21, 8), 'source': 'Mes évènements'}),
        isFalse,
      );
    });
  });

  group('Est-ce que j\'ai cours ?', () {
    final breaks = SchoolRules.builtIn('A');

    test('un jour de cours normal', () {
      final d = SchoolRules.classify(DateTime(2026, 11, 25), events: day(DateTime(2026, 11, 25)), breaks: breaks);
      expect(d.kind, SchoolDayKind.cours);
      expect(d.first, DateTime(2026, 11, 25, 8));
      expect(d.last, DateTime(2026, 11, 25, 16, 30));
      expect(d.gaps.single.lunch, isTrue);
      expect(d.freePeriods, isEmpty);
      expect(SchoolRules.sayDay(d, DateTime(2026, 11, 24, 20)), startsWith('Demain : cours de 8 h à 16 h 30'));
    });

    test('le premier cours annulé : on commence plus tard', () {
      final d = SchoolRules.classify(
        DateTime(2026, 11, 26),
        events: day(DateTime(2026, 11, 26), off: {'MATHS'}),
        breaks: breaks,
      );
      expect(d.lateStart, isTrue);
      expect(d.first, DateTime(2026, 11, 26, 9));
      final say = SchoolRules.sayDay(d, DateTime(2026, 11, 25, 21));
      expect(say, contains('Tu commences à 9 h au lieu de 8 h'));
      expect(SchoolRules.cancelImpact(d, day(DateTime(2026, 11, 26)).first), 'Tu commences à 9 h au lieu de 8 h.');
    });

    test('un cours annulé au milieu : un trou', () {
      final events = day(DateTime(2026, 11, 26), off: {'SVT'});
      final d = SchoolRules.classify(DateTime(2026, 11, 26), events: events, breaks: breaks);
      expect(d.freePeriods.single.from, DateTime(2026, 11, 26, 10));
      expect(SchoolRules.cancelImpact(d, events[2]), '1 h de libre (10 h – 11 h).');
      final m = SchoolRules.moment(DateTime(2026, 11, 26, 10, 20), d);
      expect(m.phase, SchoolPhase.trou);
      expect(m.freeTime, isTrue);
      expect(SchoolRules.sayMoment(m), 'Heure de libre jusqu\'à 11 h (puis ANGLAIS).');
    });

    test('les derniers cours annulés : on finit plus tôt', () {
      final events = day(DateTime(2026, 11, 26), off: {'EPS'});
      final d = SchoolRules.classify(DateTime(2026, 11, 26), events: events, breaks: breaks);
      expect(d.earlyEnd, isTrue);
      expect(SchoolRules.cancelImpact(d, events.last), 'Tu finis à 14 h 30 au lieu de 16 h 30.');
    });

    test('tous les cours annulés', () {
      final all = {'MATHS', 'FRANCAIS', 'SVT', 'ANGLAIS', 'HISTOIRE', 'EPS'};
      final d = SchoolRules.classify(
        DateTime(2026, 11, 26),
        events: day(DateTime(2026, 11, 26), off: all),
        breaks: breaks,
      );
      expect(d.kind, SchoolDayKind.annule);
      expect(d.noClass, isTrue);
      expect(
        SchoolRules.sayDay(d, DateTime(2026, 11, 26, 7)),
        startsWith('Pas de cours aujourd\'hui : tous tes cours'),
      );
    });

    test('le week-end, un jour férié, les vacances', () {
      expect(
        SchoolRules.classify(DateTime(2026, 11, 28), events: day(DateTime(2026, 11, 27)), breaks: breaks).kind,
        SchoolDayKind.weekend,
      );
      final armistice = SchoolRules.classify(DateTime(2026, 11, 11), events: const [], breaks: breaks);
      expect(armistice.kind, SchoolDayKind.ferie);
      expect(SchoolRules.sayDay(armistice, DateTime(2026, 11, 10)), 'Pas de cours demain : ce sera férié (Armistice).');
      final noel = SchoolRules.classify(DateTime(2026, 12, 22), events: const [], breaks: breaks);
      expect(noel.kind, SchoolDayKind.vacances);
      expect(
        SchoolRules.sayDay(noel, DateTime(2026, 12, 22, 10)),
        'Pas de cours aujourd\'hui : vacances de Noël, reprise le lundi 4 janvier.',
      );
    });

    test('un jour de semaine vide : « libre » seulement si la semaine a des cours', () {
      final wed = DateTime(2026, 11, 25);
      final week = [...day(DateTime(2026, 11, 24)), ...day(DateTime(2026, 11, 26))];
      expect(SchoolRules.classify(wed, events: week, breaks: breaks).kind, SchoolDayKind.libre);
      expect(SchoolRules.classify(wed, events: const [], breaks: breaks).kind, SchoolDayKind.inconnu);
      expect(SchoolRules.classify(wed, events: week, breaks: breaks, known: false).kind, SchoolDayKind.inconnu);
    });
  });

  group('Où on en est dans la journée', () {
    final d0 = DateTime(2026, 11, 25);
    final today = SchoolRules.classify(d0, events: day(d0));

    test('avant, en cours, midi, fini', () {
      expect(SchoolRules.moment(DateTime(2026, 11, 25, 7, 30), today).phase, SchoolPhase.avant);
      final inClass = SchoolRules.moment(DateTime(2026, 11, 25, 10, 15), today);
      expect(inClass.phase, SchoolPhase.enCours);
      expect(inClass.inClass, isTrue);
      expect(SchoolRules.sayMoment(inClass), 'En ce moment : SVT jusqu\'à 11 h.');
      expect(SchoolRules.moment(DateTime(2026, 11, 25, 12, 30), today).phase, SchoolPhase.midi);
      expect(SchoolRules.moment(DateTime(2026, 11, 25, 17), today).phase, SchoolPhase.fini);
      final sunday = SchoolRules.classify(DateTime(2026, 11, 29), events: const []);
      expect(SchoolRules.moment(DateTime(2026, 11, 29, 10), sunday).phase, SchoolPhase.pasCours);
    });
  });

  group('Le point complet (pour Nexo)', () {
    test('pendant les vacances : la rentrée et pas de cours du jour', () {
      final now = DateTime(2026, 12, 21, 10);
      final events = [...day(DateTime(2027, 1, 4)), ...day(DateTime(2027, 1, 5))];
      final r = SchoolRules.report(now, events: events, breaks: SchoolRules.builtIn('A'), zone: 'A');
      expect(r.onBreak, isTrue);
      expect(r.breakStarts, isTrue);
      expect(r.nextDay, DateTime(2027, 1, 4));
      expect(r.sayNextDay(), 'Le lundi 4 janvier à 8 h (MATHS).');
      expect(r.sayToday(), contains('vacances de Noël'));
      final block = r.promptBlock();
      expect(block, contains('pas de cours aujourd\'hui'));
      expect(block, contains('Rentrée : Le lundi 4 janvier'));
      expect(block, contains('zone A'));
      expect(r.toJson()['maintenant'], 'pasCours');
    });

    test('la veille de la rentrée', () {
      final now = DateTime(2027, 1, 3, 18);
      final r = SchoolRules.report(now, events: day(DateTime(2027, 1, 4)), breaks: SchoolRules.builtIn('A'));
      expect(r.backTomorrow, isTrue);
      expect(r.sayNextDay(), 'Demain à 8 h (MATHS).');
    });

    test('un jour de cours : les prochaines vacances et les jours qui restent', () {
      final now = DateTime(2026, 12, 14, 18);
      final r = SchoolRules.report(now, events: day(DateTime(2026, 12, 14)), breaks: SchoolRules.builtIn('A'));
      expect(r.moment.phase, SchoolPhase.fini);
      expect(r.nextBreak!.name, 'Vacances de Noël');
      expect(r.schoolDaysToBreak, 4);
      expect(r.sayNextBreak(), contains('Plus que 4 jours de cours'));
      expect(r.sayNextBreak(), startsWith('Les vacances de Noël commencent dans 5 jours'));
    });

    test('en classe : Nexo se fait discret', () {
      final now = DateTime(2026, 11, 25, 9, 15);
      final r = SchoolRules.report(now, events: day(DateTime(2026, 11, 25)));
      expect(r.moment.inClass, isTrue);
      expect(r.promptBlock(), contains('sans doute en classe'));
    });
  });

  group('Le service (zone, calendrier officiel, dernier point)', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await ModuleStore.init();
      SchoolCalendar.instance.reset();
      SchoolCalendar.fetchOverride = null;
    });

    test('la zone devinée d\'après la ville ne remplace pas un choix', () async {
      final cal = SchoolCalendar.instance;
      SchoolCalendar.fetchOverride = (url) async => url.host.contains('open-meteo')
          ? {
              'results': [
                {
                  'name': 'Lyon',
                  'country_code': 'FR',
                  'postcodes': ['69001'],
                  'admin1': 'Auvergne-Rhône-Alpes',
                },
              ],
            }
          : {'results': const []};
      expect(await cal.guessFromCity('Lyon'), 'A');
      expect(cal.zone, 'A');
      expect(cal.zoneGuessed, isTrue);
      await cal.setZone('C');
      expect(await cal.guessFromCity('Lyon'), 'C');
      expect(cal.zone, 'C');
    });

    test('le calendrier officiel lu remplace la table intégrée', () async {
      final cal = SchoolCalendar.instance;
      Uri? asked;
      SchoolCalendar.fetchOverride = (url) async {
        asked = url;
        return {
          'results': [
            {
              'description': 'Vacances d\'Hiver',
              'population': '-',
              'start_date': '2027-02-12T23:00:00+00:00',
              'end_date': '2027-02-28T23:00:00+00:00',
              'zones': 'Zone A',
            },
          ],
        };
      };
      await cal.setZone('A');
      await cal.refresh(force: true);
      expect(asked!.queryParameters['where'], contains('zones="Zone A"'));
      expect(cal.official, hasLength(1));
      expect(SchoolRules.breakOn(DateTime(2027, 2, 15), cal.breaks())!.source, 'officiel');
    });

    test('le dernier point répond tout de suite (robots, discrétion en cours)', () {
      final cal = SchoolCalendar.instance;
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final r = cal.build(now, events: day(today));
      expect(cal.last, same(r));
      if (today.weekday <= 5 &&
          SchoolRules.publicHoliday(today) == null &&
          SchoolRules.breakOn(today, cal.breaks()) == null) {
        expect(cal.hasClassOn(today), isTrue);
      }
      expect(cal.hasClassOn(DateTime(2026, 12, 25)), isFalse);
    });
  });

  group('Tout communique : le fil, les réponses sans IA, les robots, les idées', () {
    final breaks = SchoolRules.builtIn('A');

    Map schoolAt(DateTime now, List<Map> events) =>
        SchoolRules.report(now, events: events, breaks: breaks, zone: 'A').toJson();

    test('le fil : la veille de la reprise, avec les devoirs à rendre', () {
      final now = DateTime(2027, 1, 3, 18);
      final items = HubFeed.build(
        school: schoolAt(now, day(DateTime(2027, 1, 4))),
        homework: [
          {'matiere': 'Maths', 'pour_le': DateTime(2027, 1, 4), 'contenu': 'Ex 3'},
        ],
        now: now,
      );
      expect(items.first.title, 'Demain, c\'est la reprise');
      expect(items.first.detail, contains('1 devoir à rendre'));
      expect(HubFeed.say(items.first), startsWith('Demain, c\'est la reprise. Demain à 8 h (MATHS)'));
    });

    test('le fil : bonnes vacances, et jamais « CONGÉS » comme prochain cours', () {
      final now = DateTime(2026, 12, 19, 11);
      final conge = lesson('CONGES', DateTime(2026, 12, 21), 23 * 60, conge: true);
      final items = HubFeed.build(school: schoolAt(now, [conge]), events: [conge], now: now);
      expect(items.first.title, 'Bonnes vacances ! 🎉');
      expect(items.where((i) => i.title.contains('CONGES')), isEmpty);
    });

    test('le fil : premier cours annulé ce matin', () {
      final now = DateTime(2026, 11, 26, 7);
      final items = HubFeed.build(
        school: schoolAt(now, day(DateTime(2026, 11, 26), off: {'MATHS'})),
        now: now,
      );
      expect(items.first.title, 'Tu commences à 9 h aujourd\'hui');
      expect(items.first.priority, greaterThanOrEqualTo(75));
    });

    test('les réponses sans IA', () async {
      final now = DateTime(2026, 12, 21, 10);
      final events = [...day(DateTime(2027, 1, 4))];
      Future<Object?> call(String name, Map<String, dynamic> args) async {
        if (name == 'agenda_ecole') {
          final d = DateTime.tryParse('${args['date'] ?? ''}');
          if (d == null) return schoolAt(now, events);
          final info = SchoolRules.classify(d, events: events, breaks: breaks);
          return {'resume': SchoolRules.sayDay(info, now), ...info.toJson()};
        }
        if (name == 'agenda_vacances') {
          return {
            'zone': 'zone A',
            'a_venir': [for (final b in breaks) b.toJson()],
          };
        }
        return null;
      }

      Future<String?> ask(String q) async =>
          (await QuickAnswers.answer(q, call: call, tools: {'agenda_ecole', 'agenda_vacances'}, now: now))?.text;

      expect(await ask('J\'ai cours demain ?'), startsWith('Non ! Pas de cours demain : vacances de Noël'));
      expect(await ask('c\'est quand la rentrée ?'), 'Tu reprends les cours : le lundi 4 janvier à 8 h (MATHS).');
      expect(await ask('est-ce que je suis en vacances ?'), startsWith('Oui !'));
      expect(await ask('c\'est quand les vacances d\'hiver ?'), contains('13 février'));
      expect(await ask('c\'est férié le 25 ?'), isNull); // pas un jour compris : vers l'IA
      expect(await ask('le prochain jour férié'), 'Le prochain jour férié : Noël, le vendredi 25 décembre.');
      expect(await ask('je finis à quelle heure lundi ?'), isNotNull);
      // Une vraie question reste pour l'IA.
      expect(await ask('pourquoi les vacances de noël existent ?'), isNull);
    });

    test('les réponses sans IA, un jour de cours', () async {
      final now = DateTime(2026, 11, 26, 7, 30);
      final events = [
        ...day(DateTime(2026, 11, 26), off: {'SVT'}),
        ...day(DateTime(2026, 11, 27)),
      ];
      Future<Object?> call(String name, Map<String, dynamic> args) async =>
          name == 'agenda_ecole' ? schoolAt(now, events) : null;
      Future<String?> ask(String q) async =>
          (await QuickAnswers.answer(q, call: call, tools: {'agenda_ecole'}, now: now))?.text;
      expect(await ask('je finis à quelle heure ?'), 'Aujourd\'hui, tu finis à 16 h 30.');
      expect(await ask('j\'ai un trou aujourd\'hui ?'), 'Oui, aujourd\'hui : une heure de libre (10 h – 11 h).');
      expect(await ask('je commence à quelle heure demain ?'), 'Demain, tu commences à 8 h : MATHS.');
      expect(await ask('j\'ai cours demain'), startsWith('Oui, demain : 8 h MATHS, 9 h FRANCAIS'));
    });

    test('les robots : la veille d\'un jour de cours, pas pendant les vacances', () {
      final r = RobotRules.template('devoirs_soir')!.build();
      final at = DateTime(2026, 12, 22, 19, 1);
      expect(RobotRules.firesOnTick(r, RobotTick(now: at, schoolTomorrow: false), null), isFalse);
      expect(RobotRules.firesOnTick(r, RobotTick(now: at, schoolTomorrow: true), null), isTrue);
      // On ne sait pas : il part quand même (comme avant).
      expect(RobotRules.firesOnTick(r, RobotTick(now: at), null), isTrue);
      // Un ancien robot tout prêt (sans la règle) la reprend de son modèle.
      final old = Robot.fromJson({...r.toJson()..remove('ecole')})!;
      expect(old.school, 'veille');
      final mine = RobotRules.parse('tous les jours de cours à 7h, dis-moi de prendre mon sac')!;
      expect(mine.school, 'ecole');
      expect(mine.value, '7:00');
      expect(mine.when, 'Tous les jours à 7 h, les jours de cours');
      final hol = RobotRules.parse('pendant les vacances, tous les jours à 10h, mets de la musique')!;
      expect(hol.school, 'libre');
      expect(
        RobotRules.firesOnTick(hol, RobotTick(now: DateTime(2026, 12, 22, 10, 1), schoolToday: false), null),
        isTrue,
      );
      expect(
        RobotRules.firesOnTick(hol, RobotTick(now: DateTime(2026, 11, 26, 10, 1), schoolToday: true), null),
        isFalse,
      );
    });

    test('les idées de Nexo : une heure de libre, le briefing plus tard sans cours', () {
      final i = Autonomy.rules(
        {'ecole': 'trou', 'libre_min': 55, 'cartes': 12},
        DateTime(2026, 11, 26, 10, 5),
        available: {'revision_lancer', 'assistant_briefing'},
      );
      expect(i!.tool, 'revision_lancer');
      expect(i.say, contains('55 minutes de libre'));
      expect(
        Autonomy.rules({'ecole': 'pasCours'}, DateTime(2026, 12, 22, 8), available: {'assistant_briefing'}),
        isNull,
      );
      expect(
        Autonomy.rules({'ecole': 'pasCours'}, DateTime(2026, 12, 22, 10), available: {'assistant_briefing'})!.say,
        startsWith('Pas cours aujourd\'hui'),
      );
    });
  });
}
