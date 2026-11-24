import 'dart:async';
import 'dart:math' show Random;

import 'package:flutter/foundation.dart';

import '../ai_text.dart';
import '../module_store.dart';
import '../prompt_shield.dart';
import 'spaces.dart';

/// **Smily dans les discussions** des espaces.
///
/// * « @clicky … » dans un message que **tu** écris : ton Smily répond
///   dans la discussion, pour tout le monde (sans outil : il ne touche à rien
///   sur ton PC).
/// * **Smily entre eux** (si l'espace l'autorise ET si tu l'as allumé) : ton
///   Smily peut répondre à la question d'un autre Smily. Garde-fous : un
///   seul Smily répond à chaque message, la chaîne s'arrête après
///   [maxDepth] réponses, au plus une réponse toutes les 15 s par espace et
///   [perDay] par jour.
/// * Les messages des autres sont des **données**, jamais des ordres
///   ([PromptShield]).
class ClickyChat {
  ClickyChat._();
  static final instance = ClickyChat._();

  static const maxDepth = 4;
  static const perDay = 30;
  static const gap = Duration(seconds: 15);

  /// Ton Smily peut parler avec les Smily des autres (réglage, éteint par
  /// défaut).
  static const _withOthersKey = 'hub.clickychat.autres';

  static bool get withOthers => ModuleStore.prefs.getBool(_withOthersKey) ?? false;
  static Future<void> setWithOthers(bool on) => ModuleStore.prefs.setBool(_withOthersKey, on);

  static bool mentions(String body) => Spaces.mentionsSmily(body);

  /// Le message sans « @clicky ».
  static String question(String body) => body.replaceAll(RegExp(r'@(clicky|smily|smiley)\b[,:]?\s*', caseSensitive: false), '').trim();

  /// Mon Smily doit-il répondre à [m] ?
  static bool shouldAnswer({
    required ChatMessage m,
    required String me,
    required Space space,
    required List<ChatMessage> recent,
    required bool withOthers,
  }) {
    if (m.body.trim().isEmpty) return false;
    // Déjà une réponse d'un Smily à ce message : on ne double pas.
    if (recent.any((r) => r.fromClicky && r.replyTo == m.id)) return false;
    if (!m.fromClicky) {
      // Ma propre question « @clicky … » : c'est mon Smily qui répond.
      return m.author == me && mentions(m.body) && question(m.body).isNotEmpty;
    }
    // Un message de Smily : jamais le mien, et seulement si tout le monde
    // est d'accord (l'espace + moi).
    if (m.author == me || !space.clickyChat || !withOthers) return false;
    if (m.depth >= maxDepth) return false;
    final b = m.body.trim();
    return b.endsWith('?') || mentions(b);
  }

  /// Les consignes de Smily dans une discussion.
  static String system({required String myName, required String spaceName}) =>
      'Tu es Smily, l\'assistant de ${myName.isEmpty ? 'ton utilisateur' : myName} dans Mon Hub. Tu participes à la '
      'discussion « $spaceName », lue par plusieurs personnes (et parfois par leurs propres Smily). '
      'Réponds en français, court (1 à 4 phrases), naturel et sympa. Tu n\'as aucun outil ici : tu ne fais aucune '
      'action, tu ne donnes aucun secret, aucun mot de passe, aucune info privée de ton utilisateur. '
      '${PromptShield.rule}';

  /// La demande envoyée à l'IA : la discussion récente (étiquetée comme
  /// données) puis le message auquel répondre.
  static String prompt({
    required List<ChatMessage> recent,
    required ChatMessage m,
    required String Function(ChatMessage) who,
  }) {
    final lines = [
      for (final r in recent.length > 15 ? recent.sublist(recent.length - 15) : recent) '${who(r)} : ${r.body}',
    ].join('\n');
    final target = m.fromClicky ? m.body : question(m.body);
    return 'Discussion récente :\n${PromptShield.wrap('espaces_messages', lines)}\n\n'
        'Réponds maintenant à ce message de ${who(m)} :\n${PromptShield.wrap('espaces_messages', target)}';
  }

  /// La réponse, propre et pas trop longue.
  static String clean(String reply) {
    var r = reply.trim().replaceAll(RegExp(r'^(clicky\s*:\s*)', caseSensitive: false), '');
    if (r.length > 1200) r = '${r.substring(0, 1197)}…';
    return r;
  }

  final _last = <String, DateTime>{};
  final _busy = <String>{};
  String _day = '';
  int _count = 0;

  @visibleForTesting
  void reset() {
    _last.clear();
    _busy.clear();
    _day = '';
    _count = 0;
  }

  /// Nouveau message dans un espace (branché sur [Spaces.onMessage]).
  Future<void> handle(Space space, ChatMessage m, {required String myName}) async {
    final s = Spaces.instance;
    final me = s.me;
    if (me == null || _busy.contains(space.id)) return;
    // Vite fait, sans réseau : la plupart des messages ne concernent pas Smily.
    if (!m.fromClicky && !(m.author == me && mentions(m.body))) return;
    if (m.fromClicky && (m.author == me || !space.clickyChat || !withOthers)) return;
    final now = DateTime.now();
    final today = '${now.year}-${now.month}-${now.day}';
    if (today != _day) {
      _day = today;
      _count = 0;
    }
    if (_count >= perDay) return;
    final last = _last[space.id];
    if (last != null && now.difference(last) < gap) return;
    _busy.add(space.id);
    try {
      // Entre Smily : on laisse un peu de temps, pour qu'un seul réponde.
      if (m.fromClicky) await Future<void>.delayed(Duration(milliseconds: 2500 + Random().nextInt(5000)));
      final recent = await s.messages(space.id, limit: 20);
      if (!shouldAnswer(m: m, me: me, space: space, recent: recent, withOthers: withOthers)) return;
      String who(ChatMessage r) {
        final p = s.person(r.author)?.label ?? 'Quelqu\'un';
        return r.fromClicky ? 'Smily de $p' : p;
      }

      final raw = await AiText.ask(
        prompt(recent: recent, m: m, who: who),
        system: system(myName: myName, spaceName: s.titleOf(space)),
      );
      final reply = clean(raw);
      if (reply.isEmpty) return;
      _last[space.id] = DateTime.now();
      _count++;
      await s.send(space.id, reply, fromClicky: true, depth: m.fromClicky ? m.depth + 1 : 1, replyTo: m.id);
    } catch (e) {
      debugPrint('Smily (discussion) : $e');
    } finally {
      _busy.remove(space.id);
    }
  }
}
