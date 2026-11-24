/// Corriger (ou reformuler, traduire) **le texte surligné dans n'importe
/// quelle appli** : Nexo le copie, l'IA le corrige, et il le recolle à la
/// place. Ici : les consignes de l'IA et le nettoyage de sa réponse.
class TextFix {
  TextFix._();

  static const system =
      'Tu es un correcteur de texte. Tu renvoies uniquement le texte demandé, sans guillemets, sans explication, '
      'sans phrase d\'introduction.';

  /// [mode] : « corriger » (défaut), « reformuler », ou « traduire:anglais ».
  static String prompt(String text, {String mode = 'corriger'}) {
    final m = mode.trim().toLowerCase();
    final what = m.startsWith('traduire')
        ? 'Traduis ce texte en ${m.contains(':') ? m.split(':').last.trim() : 'anglais'}, naturellement, en gardant le ton.'
        : m == 'reformuler'
        ? 'Reformule ce texte pour qu\'il soit plus clair et mieux écrit, sans changer le sens ni le ton, et corrige les fautes.'
        : 'Corrige uniquement l\'orthographe, la grammaire, la conjugaison, les accords, les accents et la ponctuation. '
              'Ne change ni le style, ni les mots, ni le sens, ni le niveau de langue (un message entre amis reste '
              'familier). Garde la même langue.';
    return '$what Garde les retours à la ligne, les émojis, les noms propres et les liens tels quels. '
        'Réponds uniquement avec le texte final.\n\n<<<\n$text\n>>>';
  }

  /// La réponse de l'IA, débarrassée de ce qui n'est pas le texte (« ```,
  /// guillemets, <<< >>>), avec les espaces du début et de la fin du texte
  /// d'origine.
  static String clean(String answer, String original) {
    var t = answer.trim();
    t = t.replaceAll(RegExp(r'^```[a-zA-Z]*\s*|\s*```$'), '');
    t = t.replaceAll(RegExp(r'^<<<\s*|\s*>>>$'), '').trim();
    for (final (a, b) in const [('"', '"'), ('«', '»'), ('“', '”')]) {
      final quoted = original.trim().startsWith(a);
      if (!quoted && t.length > 1 && t.startsWith(a) && t.endsWith(b)) t = t.substring(1, t.length - 1).trim();
    }
    final lead = RegExp(r'^\s*').firstMatch(original)!.group(0)!;
    final trail = RegExp(r'\s*$').firstMatch(original)!.group(0)!;
    return '$lead$t$trail';
  }

  /// Nombre de mots changés (distance entre les deux listes de mots).
  static int changes(String a, String b) {
    final x = a.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final y = b.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (x.length > 3000 || y.length > 3000) return (x.length - y.length).abs();
    var prev = List<int>.generate(y.length + 1, (j) => j);
    for (var i = 1; i <= x.length; i++) {
      final cur = List<int>.filled(y.length + 1, 0)..[0] = i;
      for (var j = 1; j <= y.length; j++) {
        final cost = x[i - 1] == y[j - 1] ? 0 : 1;
        final best = prev[j - 1] + cost;
        final del = prev[j] + 1, ins = cur[j - 1] + 1;
        cur[j] = best < del ? (best < ins ? best : ins) : (del < ins ? del : ins);
      }
      prev = cur;
    }
    return prev[y.length];
  }
}
