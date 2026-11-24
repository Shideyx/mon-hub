import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_ui/material_ui.dart';

import 'web_login.dart';

/// Un appel (vocal ou vidéo) Discord ou Instagram **dans Mon Hub** : la
/// conversation s'ouvre sur le vrai site (ton compte habituel, déjà
/// connecté dans Mon Hub), le micro et la caméra sont autorisés, et Mon Hub
/// appuie tout seul sur le bouton d'appel.
class CallPage extends StatefulWidget {
  const CallPage({super.key, required this.url, required this.title, required this.video, this.color});

  final String url;
  final String title;
  final bool video;
  final Color? color;

  static Future<void> open(
    BuildContext context, {
    required String url,
    required String title,
    required bool video,
    Color? color,
  }) => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => CallPage(url: url, title: title, video: video, color: color),
    ),
  );

  /// Le script qui trouve et appuie sur le bouton d'appel (français ou
  /// anglais, Discord et Instagram).
  static String clickScript({required bool video}) {
    final words = video
        ? 'appel vidéo|video call|démarrer un appel vidéo'
        : 'appel vocal|appel audio|voice call|audio call|démarrer un appel vocal';
    return '''
(function () {
  var re = new RegExp("($words)", "i");
  var els = document.querySelectorAll('[aria-label], [title]');
  for (var i = 0; i < els.length; i++) {
    var e = els[i];
    var l = (e.getAttribute('aria-label') || e.getAttribute('title') || '');
    if (re.test(l)) {
      var b = e.closest('button, [role="button"], a') || e;
      b.click();
      return true;
    }
  }
  return false;
})();
''';
  }

  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> {
  InAppWebViewController? _c;
  Timer? _try;
  String status = 'Je lance l\'appel…';
  bool started = false;

  @override
  void dispose() {
    _try?.cancel();
    super.dispose();
  }

  void _start(InAppWebViewController c) {
    _c = c;
    var tries = 0;
    _try = Timer.periodic(const Duration(milliseconds: 1500), (t) async {
      if (!mounted || started) return t.cancel();
      if (++tries > 20) {
        t.cancel();
        setState(() => status = 'Appuie sur le bouton ${widget.video ? '📹' : '📞'} en haut de la conversation.');
        return;
      }
      try {
        final ok = await _c?.evaluateJavascript(source: CallPage.clickScript(video: widget.video));
        if (ok == true && mounted) {
          t.cancel();
          setState(() {
            started = true;
            status = 'Appel en cours : raccroche avec le bouton rouge.';
          });
        }
      } catch (_) {}
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Row(
        children: [
          Icon(widget.video ? Icons.videocam_rounded : Icons.call_rounded, color: widget.color),
          const SizedBox(width: 10),
          Expanded(child: Text(widget.title, overflow: TextOverflow.ellipsis)),
        ],
      ),
    ),
    body: Column(
      children: [
        Material(
          color: (widget.color ?? Theme.of(context).colorScheme.primary).withValues(alpha: 0.12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                if (!started) const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                if (!started) const SizedBox(width: 10),
                Expanded(child: Text(status)),
              ],
            ),
          ),
        ),
        Expanded(
          child: HubWebView(url: widget.url, desktopUserAgent: true, onController: _start),
        ),
      ],
    ),
  );
}
