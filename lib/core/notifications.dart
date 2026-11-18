import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'hub_controller.dart';
import 'module_store.dart';
import 'freeze_watch.dart';
import 'screen_time.dart';
import '../ui/clicky/jarvis.dart';

/// Une alerte produite par un module (nouveau mail, nouveau message…).
class HubNotification {
  HubNotification({
    required this.id,
    required this.title,
    required this.body,
    this.moduleId = '',
    DateTime? at,
  }) : at = at ?? DateTime.now();

  /// Identifiant stable : une même alerte n'est jamais montrée deux fois.
  final String id;
  final String title;
  final String body;
  String moduleId;
  final DateTime at;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'body': body,
    'moduleId': moduleId,
    'at': at.toIso8601String(),
  };

  factory HubNotification.fromJson(Map<String, dynamic> j) => HubNotification(
    id: j['id'] as String,
    title: j['title'] as String,
    body: j['body'] as String,
    moduleId: j['moduleId'] as String? ?? '',
    at: DateTime.tryParse(j['at'] as String? ?? ''),
  );
}

/// Interroge régulièrement les modules actifs et affiche une alerte système
/// (toast Windows, notification Android/iOS/Mac/Linux) pour chaque nouveauté.
///
/// Les alertes arrivent tant que l'appli tourne (même réduite / en arrière-plan
/// sur ordinateur). Sur téléphone, Android peut la mettre en pause quand elle
/// est fermée depuis longtemps.
class NotificationCenter extends ChangeNotifier {
  NotificationCenter(this.hub);

  final HubController hub;
  final _plugin = FlutterLocalNotificationsPlugin();
  Timer? _timer;
  bool _ready = false;
  bool _polling = false;

  static const _seenKey = 'notif.seen';
  static const _historyKey = 'notif.history';
  static const _seededKey = 'notif.seeded';
  static const _mutedKey = 'notif.muted';
  static const _intervalKey = 'notif.interval';

  /// Minutes entre deux vérifications.
  int get interval => ModuleStore.prefs.getInt(_intervalKey) ?? 2;
  set interval(int v) {
    ModuleStore.prefs.setInt(_intervalKey, v);
    _schedule();
    notifyListeners();
  }

  static const _digestKey = 'notif.digest';

  /// Regrouper les notifications des modules : toutes les [digest] minutes
  /// un seul résumé (0 = chacune tout de suite). Les appels passent toujours.
  int get digest => ModuleStore.prefs.getInt(_digestKey) ?? 30;
  set digest(int v) {
    ModuleStore.prefs.setInt(_digestKey, v);
    if (v == 0) unawaited(flushDigest());
    notifyListeners();
  }

  final _held = <HubNotification>[];
  Timer? _digestTimer;

  /// Ce qui passe toujours tout de suite (un appel qui sonne…).
  static bool urgent(HubNotification n) =>
      n.moduleId.isEmpty || n.id.startsWith('discord-appel') || n.id.startsWith('annule:') || n.id.startsWith('arnaque:');

  /// Le résumé : « 3 messages Discord, 1 mail… » puis quelques lignes.
  static HubNotification digestOf(List<HubNotification> items, Map<String, String> names, {DateTime? at}) {
    final counts = <String, int>{};
    for (final n in items) {
      final k = names[n.moduleId] ?? (n.moduleId.isEmpty ? 'Mon Hub' : n.moduleId);
      counts[k] = (counts[k] ?? 0) + 1;
    }
    final head = [for (final e in counts.entries) '${e.value} ${e.key}'].join(' · ');
    final lines = [
      for (final n in items.reversed.take(5)) '• ${n.title}${n.body.isEmpty ? '' : ' — ${n.body.split('\n').first}'}',
      if (items.length > 5) '… et ${items.length - 5} autre${items.length - 5 > 1 ? 's' : ''}',
    ];
    return HubNotification(
      id: 'resume-${(at ?? DateTime.now()).millisecondsSinceEpoch}',
      title: '🔔 ${items.length} notification${items.length > 1 ? 's' : ''} : $head',
      body: lines.join('\n'),
    );
  }

  /// Envoie le résumé maintenant (s'il y a quelque chose).
  Future<void> flushDigest() async {
    _digestTimer?.cancel();
    _digestTimer = null;
    if (_held.isEmpty) return;
    final items = [..._held];
    _held.clear();
    final names = {for (final m in hub.enabled) m.id: m.name};
    final d = items.length == 1 ? items.first : digestOf(items, names);
    if (!banners.isClosed) banners.add(d);
    await show(d);
  }

  Set<String> get muted => (ModuleStore.prefs.getStringList(_mutedKey) ?? const []).toSet();

  bool isMuted(String moduleId) => muted.contains(moduleId);

  void setMuted(String moduleId, bool value) {
    final m = muted;
    value ? m.add(moduleId) : m.remove(moduleId);
    ModuleStore.prefs.setStringList(_mutedKey, m.toList());
    notifyListeners();
  }

  List<HubNotification> get history => (ModuleStore.prefs.getStringList(_historyKey) ?? const [])
      .map((s) => HubNotification.fromJson(jsonDecode(s) as Map<String, dynamic>))
      .toList();

  /// Alertes à montrer **dans la fenêtre** (bandeaux en haut à droite).
  final banners = StreamController<HubNotification>.broadcast();

  /// Publie une alerte : historique (cloche), bandeau dans la fenêtre et
  /// notification du système.
  Future<void> post(HubNotification n, {bool system = true}) async {
    final prefs = ModuleStore.prefs;
    await prefs.setStringList(
      _historyKey,
      [jsonEncode(n.toJson()), ...prefs.getStringList(_historyKey) ?? const <String>[]].take(100).toList(),
    );
    unread++;
    notifyListeners();
    // Mode concentration : gardée pour la fin (sauf un appel qui sonne).
    final focus = FocusMode.instance;
    await focus.sync();
    if (focus.active && !n.id.startsWith('discord-appel')) {
      await focus.holdOne();
      return;
    }
    // Mode jeu : gardée pour la fin de la partie (sauf un appel, une arnaque).
    final game = GameMode.instance;
    if (game.active && !n.id.startsWith('discord-appel') && !n.id.startsWith('arnaque:')) {
      game.held++;
      return;
    }
    // Regroupées : un seul résumé toutes les 30 min (ou 1 h).
    if (digest > 0 && system && !urgent(n)) {
      _held.add(n);
      _digestTimer ??= Timer(Duration(minutes: digest), () => unawaited(flushDigest()));
      return;
    }
    if (!banners.isClosed) banners.add(n);
    if (system) await show(n);
  }

  int unread = 0;
  void markRead() {
    unread = 0;
    notifyListeners();
  }

  Future<void> start() async {
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(),
          macOS: DarwinInitializationSettings(),
          linux: LinuxInitializationSettings(defaultActionName: 'Ouvrir'),
          windows: WindowsInitializationSettings(
            appName: 'Mon Hub',
            appUserModelId: 'fr.erik.hub',
            guid: '6f1d6c1e-5a43-4c7b-9d0e-6a3f2c8b7e41',
          ),
        ),
      );
      if (!kIsWeb && Platform.isAndroid) {
        await _plugin
            .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
      }
      _ready = true;
    } catch (e) {
      debugPrint('Notifications indisponibles : $e');
    }
    _schedule();
    unawaited(pollNow());
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer.periodic(Duration(minutes: interval), (_) => pollNow());
  }

  Future<void> pollNow() async {
    if (_polling) return;
    FreezeWatch.note('vérifie les notifications');
    _polling = true;
    try {
      final prefs = ModuleStore.prefs;
      final seen = (prefs.getStringList(_seenKey) ?? const []).toList();
      final seenSet = seen.toSet();
      final seeded = (prefs.getStringList(_seededKey) ?? const []).toSet();
      final fresh = <HubNotification>[];

      for (final m in hub.enabled) {
        List<HubNotification> items;
        try {
          items = await m.poll();
        } catch (e) {
          debugPrint('poll ${m.id}: $e');
          continue;
        }
        // Premier passage d'un module : on mémorise sans alerter, pour ne
        // pas recevoir 50 alertes d'anciens messages d'un coup.
        final first = !seeded.contains(m.id);
        for (final n in items) {
          final key = '${m.id}:${n.id}';
          if (seenSet.add(key)) {
            seen.add(key);
            n.moduleId = m.id;
            if (!first && !isMuted(m.id)) fresh.add(n);
          }
        }
        if (first) seeded.add(m.id);
      }

      if (seen.length > 2000) seen.removeRange(0, seen.length - 2000);
      await prefs.setStringList(_seenKey, seen);
      await prefs.setStringList(_seededKey, seeded.toList());

      for (final n in fresh.reversed) {
        await post(n);
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> show(HubNotification n) async {
    if (!_ready) return;
    try {
      await _plugin.show(
        id: n.id.hashCode & 0x7fffffff,
        title: n.title,
        body: n.body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'hub',
            'Mon Hub',
            channelDescription: 'Nouveaux messages, mails et cours',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
          macOS: DarwinNotificationDetails(),
          linux: LinuxNotificationDetails(),
          windows: WindowsNotificationDetails(),
        ),
      );
    } catch (e) {
      debugPrint('show notification: $e');
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(banners.close());
    super.dispose();
  }
}
