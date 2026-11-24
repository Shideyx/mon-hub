import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

/// Surveille les moments où l'appli **fige** (« Ne répond pas ») : un petit
/// guetteur, à côté, attend un battement de l'appli toutes les demi-secondes.
/// Si le battement n'arrive plus pendant 4 s, il note dans le journal des
/// erreurs (sur le PC seulement) depuis quand, et ce que l'appli faisait
/// (« doing ») : ça permet de trouver et corriger la cause.
class FreezeWatch {
  FreezeWatch._();

  static SendPort? _to;
  static Timer? _beat;

  /// Ce que l'appli est en train de faire (ouvre un module, Smily réfléchit…).
  static String doing = 'démarrage';
  static DateTime _since = DateTime.now();

  /// Note ce que l'appli commence à faire (affiché si elle fige).
  static void note(String what) {
    doing = what;
    _since = DateTime.now();
  }

  static Future<void> start(String who, String? logPath) async {
    if (kIsWeb || kDebugMode || logPath == null || _beat != null) return;
    try {
      final hello = ReceivePort();
      await Isolate.spawn(_watch, [hello.sendPort, logPath, who], debugName: 'guetteur', errorsAreFatal: false);
      _to = await hello.first as SendPort;
      _beat = Timer.periodic(const Duration(milliseconds: 500), (_) {
        final secs = DateTime.now().difference(_since).inSeconds;
        _to?.send(secs > 0 ? '$doing (depuis $secs s)' : doing);
      });
    } catch (_) {}
  }

  /// Le guetteur (dans son propre fil : il marche même quand l'appli fige).
  static void _watch(List<Object> args) {
    final reply = args[0] as SendPort;
    final path = args[1] as String;
    final who = args[2] as String;
    final port = ReceivePort();
    reply.send(port.sendPort);
    var last = DateTime.now();
    var doing = '';
    DateTime? frozen;
    var tick = DateTime.now();

    void write(String text) {
      try {
        final f = File(path);
        if (f.existsSync() && f.lengthSync() > 512 * 1024) return;
        f.writeAsStringSync(
          '[${DateTime.now().toIso8601String()}] $who / figé\n$text\n\n',
          mode: FileMode.append,
          flush: true,
        );
      } catch (_) {}
    }

    port.listen((m) {
      final now = DateTime.now();
      if (frozen != null) {
        final s = now.difference(frozen!).inMilliseconds / 1000;
        if (s >= 4) write('L\'appli a de nouveau répondu après ${s.toStringAsFixed(1)} s (pendant : $doing).');
        frozen = null;
      }
      last = now;
      if (m is String) doing = m;
    });

    Timer.periodic(const Duration(seconds: 1), (_) {
      final now = DateTime.now();
      // Le PC sortait de veille : ce n'est pas l'appli qui a figé.
      if (now.difference(tick) > const Duration(seconds: 3)) last = now;
      tick = now;
      if (frozen == null && now.difference(last) > const Duration(seconds: 4)) {
        frozen = last;
        write('L\'appli ne répond plus depuis 4 s. Elle était en train de : $doing.');
      }
    });
  }
}
