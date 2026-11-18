import '../../core/claude_api.dart';
import '../../core/tool_router.dart';

/// Clicky économe : Claude seulement pour les demandes qui en valent la
/// peine. Le reste passe par des réponses sans IA (`quick.dart`), Gemini
/// (gratuit) ou une version « légère » de Claude.
///
/// Modèle conseillé pour les demandes lourdes : **Claude Opus 5.5**
/// (`claude-opus-5-5`), en effort « low » pour une question normale et
/// « medium » pour une vraie tâche (rédiger, analyser, coder, planifier).
class ClaudeThrift {
  ClaudeThrift._();

  /// Demandes qui méritent Claude : rédiger, analyser, coder, planifier,
  /// plusieurs étapes, ou un long texte.
  static bool heavy(String question) {
    final q = ToolRouter.normalize(question);
    if (question.length > 400) return true;
    return RegExp(
      r'\b(redige|rediger|ecris moi|ecrit moi|ecris un|ecris une|dissertation|expose|commentaire|redaction|lettre de motivation'
      r'|analyse|analyser|compare|comparer|argumente|critique|corrige|corriger|ameliore|reformule tout|resume (ce|le|la|mon|ma)'
      r'|code|programme|script|algorithme|debug|python|javascript|java|html|css|sql|excel|formule'
      r'|plan detaille|organise|planifie|strategie|projet|prepare (moi )?(mon|ma|un|une)|fais (moi )?(un|une) (fiche|plan|resume|quiz)'
      r'|explique (en detail|precisement|pourquoi|comment)|demontre|resous|exercice|probleme|equation|devoir maison|dm\b'
      r'|agent|ensuite|et apres|puis)\b',
    ).hasMatch(q);
  }

  /// Effort demandé à Claude : moins il réfléchit pour une question simple,
  /// moins ça coûte.
  static String effort(String question) => heavy(question) ? 'medium' : 'low';

  /// Une question simple de culture générale, sans données de Mon Hub, sans
  /// écran, sans document : Gemini (gratuit) suffit.
  static bool light(String question, {bool screen = false, bool docs = false}) {
    if (screen || docs || question.trim().length > 260) return false;
    if (heavy(question)) return false;
    return ToolRouter.groupsFor(question).isEmpty;
  }
}

/// Ce que Claude a coûté aujourd'hui (compté sur ce PC seulement).
class ClaudeUsage {
  ClaudeUsage._();

  static String _today() {
    final d = DateTime.now();
    return '${d.year}-${d.month}-${d.day}';
  }

  static Map<String, dynamic> get _data {
    final m = ClaudeApi.store.getJson<Map>('usage');
    if (m == null || m['jour'] != _today()) return {'jour': _today(), 'claude': 0, 'evite': 0};
    return m.cast<String, dynamic>();
  }

  /// Une demande envoyée à Claude.
  static Future<void> claude() => _add('claude');

  /// Une demande traitée sans Claude (sans IA ou par Gemini).
  static Future<void> saved() => _add('evite');

  static Future<void> _add(String k) async {
    try {
      final d = _data;
      d[k] = ((d[k] as num?) ?? 0) + 1;
      await ClaudeApi.store.setJson('usage', d);
    } catch (_) {}
  }

  static int get claudeToday => ((_safe['claude'] as num?) ?? 0).toInt();
  static int get savedToday => ((_safe['evite'] as num?) ?? 0).toInt();

  static Map<String, dynamic> get _safe {
    try {
      return _data;
    } catch (_) {
      return const {};
    }
  }

  /// Phrase pour les réglages.
  static String get summary {
    final c = claudeToday, s = savedToday;
    if (c == 0 && s == 0) return 'Aujourd\'hui : aucune question pour l\'instant.';
    return 'Aujourd\'hui : $c question${c > 1 ? 's' : ''} envoyée${c > 1 ? 's' : ''} à Claude, '
        '$s réglée${s > 1 ? 's' : ''} sans Claude.';
  }
}
