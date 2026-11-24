import 'dart:async';
import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_ui/material_ui.dart';

import '../../ui/chat_history.dart';
import '../../ui/web_login.dart';
import '../../ui/widgets.dart';

/// Synchronise tes conversations de claude.ai (ton compte habituel, ouvert
/// dans l'onglet claude.ai) dans l'historique de Mon Hub, pour tout
/// retrouver au même endroit et pouvoir les continuer ici.
///
/// La page claude.ai lit elle-même tes conversations (comme quand tu les
/// ouvres) : rien ne passe ailleurs que sur ton PC. Accès non officiel :
/// peut casser si claude.ai change.
class ClaudeAiSync {
  ClaudeAiSync._();

  /// Script lancé dans la page claude.ai : range le résultat dans
  /// `window.__monhubSync` (lu ensuite par Mon Hub).
  static String script(int limit) =>
      '''
(async () => {
  window.__monhubSync = { state: 'running', done: 0 };
  try {
    const get = async (u) => {
      const r = await fetch(u, { credentials: 'include' });
      if (!r.ok) throw new Error('HTTP ' + r.status + ' ' + u);
      return r.json();
    };
    const orgs = await get('/api/organizations');
    const org = (orgs.find(o => (o.capabilities || []).includes('chat')) || orgs[0]).uuid;
    const list = await get('/api/organizations/' + org + '/chat_conversations?limit=$limit');
    const out = [];
    for (const c of list.slice(0, $limit)) {
      try {
        const d = await get('/api/organizations/' + org + '/chat_conversations/' + c.uuid + '?tree=True&rendering_mode=messages');
        out.push({
          uuid: c.uuid, name: c.name || '', created: c.created_at, updated: c.updated_at,
          msgs: (d.chat_messages || []).map(m => ({
            s: m.sender,
            at: m.created_at,
            t: (m.content || []).filter(x => x.type === 'text').map(x => x.text).join('\\n') || m.text || '',
          })),
        });
      } catch (e) {}
      window.__monhubSync.done = out.length;
    }
    window.__monhubSync = { state: 'done', data: JSON.stringify(out) };
  } catch (e) {
    window.__monhubSync = { state: 'error', error: String(e) };
  }
})();
true;
''';

  /// Transforme la réponse en conversations Mon Hub.
  static List<ChatThread> parse(String json) {
    final list = jsonDecode(json);
    if (list is! List) return const [];
    return [
      for (final c in list)
        if (c is Map && (c['msgs'] as List?)?.isNotEmpty == true)
          ChatThread(
            id: 'claudeai-${c['uuid']}',
            title: '${c['name'] ?? ''}',
            created: DateTime.tryParse('${c['created']}')?.toLocal(),
            updated: DateTime.tryParse('${c['updated']}')?.toLocal(),
            app: 'claude.ai',
            messages: [
              for (final m in c['msgs'] as List)
                if (m is Map && '${m['t'] ?? ''}'.trim().isNotEmpty)
                  ChatMsg(
                    mine: m['s'] == 'human',
                    text: '${m['t']}'.trim(),
                    at: DateTime.tryParse('${m['at']}')?.toLocal(),
                  ),
            ],
          ),
    ];
  }

  /// Lance l'import dans la page ouverte. [onProgress] reçoit le nombre de
  /// conversations déjà lues.
  static Future<int> run(InAppWebViewController c, {int limit = 60, void Function(int done)? onProgress}) async {
    final url = '${await c.getUrl()}';
    if (!url.contains('claude.ai')) throw 'Ouvre d\'abord claude.ai dans cet onglet';
    await c.evaluateJavascript(source: script(limit));
    final end = DateTime.now().add(const Duration(minutes: 4));
    while (DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 700));
      final raw = await c.evaluateJavascript(source: 'JSON.stringify(window.__monhubSync || {})');
      final Object? j = raw is String ? jsonDecode(raw) : raw;
      if (j is! Map) continue;
      switch (j['state']) {
        case 'running':
          onProgress?.call((j['done'] as num?)?.toInt() ?? 0);
        case 'error':
          final e = '${j['error']}';
          throw e.contains('401') || e.contains('403')
              ? 'Connecte-toi d\'abord à claude.ai dans cet onglet'
              : 'claude.ai a refusé : $e';
        case 'done':
          final threads = parse('${j['data']}');
          return ChatHistory.claude.upsertAll(threads);
      }
    }
    throw 'claude.ai met trop de temps à répondre';
  }
}

/// Onglet claude.ai : le site, et le bouton pour ramener tes conversations
/// dans l'historique de Mon Hub.
class ClaudeAiTab extends StatefulWidget {
  const ClaudeAiTab({super.key});

  @override
  State<ClaudeAiTab> createState() => _ClaudeAiTabState();
}

class _ClaudeAiTabState extends State<ClaudeAiTab> with AutomaticKeepAliveClientMixin {
  InAppWebViewController? _c;
  String? status;
  bool busy = false;

  @override
  bool get wantKeepAlive => true;

  Future<void> _sync() async {
    final c = _c;
    if (c == null) return;
    setState(() {
      busy = true;
      status = 'Lecture de tes conversations claude.ai…';
    });
    try {
      final n = await ClaudeAiSync.run(
        c,
        onProgress: (d) => mounted ? setState(() => status = 'Lecture de tes conversations… ($d)') : null,
      );
      status = '$n conversation${n > 1 ? 's' : ''} claude.ai dans ton historique (onglet Discuter).';
    } catch (e) {
      status = '$e';
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (!webLoginSupported) {
      return Center(
        child: FilledButton.icon(
          icon: const Icon(Icons.open_in_new_rounded),
          label: const Text('Ouvrir claude.ai'),
          onPressed: () => openLink(context, 'https://claude.ai/new'),
        ),
      );
    }
    return Column(
      children: [
        Material(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    status ?? 'Connecte-toi, puis ramène tes conversations claude.ai dans Mon Hub.',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                FilledButton.tonalIcon(
                  icon: busy
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.sync_rounded),
                  label: const Text('Synchroniser l\'historique'),
                  onPressed: busy || _c == null ? null : _sync,
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: HubWebView(
            url: 'https://claude.ai/new',
            desktopUserAgent: true,
            onController: (c) => setState(() => _c = c),
          ),
        ),
      ],
    );
  }
}
