import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../core/hub_files.dart';
import 'routines.dart';

/// Les **compagnons** de Clicky : de petits agents (chacun son nom, sa
/// couleur) qui se proposent d'eux-mêmes pour faire une tâche utile pour
/// toi — d'après tes réponses à quatre questions, tes cours, tes devoirs…
/// Tu réponds « Non », « Ajuster » ou « Oui, fais-le » ; ils travaillent en
/// arrière-plan (internet, actions de Mon Hub, ton PC avec ta permission)
/// et te préviennent quand c'est fini. Certains recommencent chaque jour.
class Buddy {
  Buddy({
    required this.id,
    required this.name,
    required this.color,
    required this.mission,
    this.detail = '',
    required this.prompt,
    this.daily = false,
    this.status = 'propose',
    this.result = '',
    DateTime? at,
  }) : at = at ?? DateTime.now();

  final String id;
  String name;
  int color;

  /// « Je vais… » : ce que le compagnon propose, en une phrase.
  String mission;
  String detail;

  /// Les consignes précises pour l'agent.
  String prompt;
  bool daily;

  /// propose, travail, fini, echec, refuse, arrete.
  String status;
  String result;
  DateTime at;

  Color get colour => Color(color);
  bool get working => status == 'travail';

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'color': color,
    'mission': mission,
    'detail': detail,
    'prompt': prompt,
    'daily': daily,
    'status': status,
    'result': result,
    'at': at.toIso8601String(),
  };

  factory Buddy.fromJson(Map<String, dynamic> j) => Buddy(
    id: '${j['id']}',
    name: '${j['name'] ?? 'Compagnon'}',
    color: (j['color'] as num?)?.toInt() ?? palette.first,
    mission: '${j['mission'] ?? ''}',
    detail: '${j['detail'] ?? ''}',
    prompt: '${j['prompt'] ?? ''}',
    daily: j['daily'] == true,
    status: '${j['status'] ?? 'propose'}',
    result: '${j['result'] ?? ''}',
    at: DateTime.tryParse('${j['at']}'),
  );

  /// Couleurs pastel des compagnons (violet, vert, bleu, rose, orange).
  static const palette = [0xFFB79CF5, 0xFF8EDDA8, 0xFF8CC8F2, 0xFFF5A3C7, 0xFFF7C27B, 0xFF9EE6E0];

  /// Lit les propositions de l'IA (JSON, éventuellement entouré de texte).
  static List<Buddy> parseProposals(String raw) {
    final start = raw.indexOf('[');
    final end = raw.lastIndexOf(']');
    if (start < 0 || end <= start) return const [];
    try {
      final list = jsonDecode(raw.substring(start, end + 1));
      if (list is! List) return const [];
      final out = <Buddy>[];
      for (final (i, x) in list.indexed) {
        if (x is! Map) continue;
        final mission = '${x['mission'] ?? ''}'.trim();
        final prompt = '${x['consignes'] ?? x['prompt'] ?? mission}'.trim();
        if (mission.isEmpty) continue;
        out.add(
          Buddy(
            id: '${DateTime.now().microsecondsSinceEpoch}$i',
            name: '${x['nom'] ?? x['name'] ?? 'Compagnon ${i + 1}'}'.trim(),
            color: palette[i % palette.length],
            mission: mission,
            detail: '${x['detail'] ?? ''}'.trim(),
            prompt: prompt,
            daily: x['chaque_jour'] == true || x['quotidien'] == true,
          ),
        );
      }
      return out;
    } catch (_) {
      return const [];
    }
  }
}

class Buddies extends ChangeNotifier {
  Buddies._();
  static final instance = Buddies._();

  /// Fait le travail d'un agent (branché sur Clicky) : renvoie le texte brut.
  Future<String> Function(String prompt)? runner;

  /// Prévient (alerte dans la fenêtre + système, voix).
  void Function(String title, String body)? onDone;

  static const questions = [
    'Qu\'est-ce que tu fais en ce moment ? (ta classe, tes projets, ce qui te passionne)',
    'Qu\'est-ce qui compterait comme une vraie réussite pour toi dans les deux prochains mois ?',
    'Qu\'est-ce qui te prend le plus de temps, ou t\'embête le plus, en ce moment ?',
    'Sur quoi aimerais-tu qu\'on t\'aide sans que tu aies à le demander ?',
  ];

  final _file = JsonFile<Map<String, dynamic>>(
    'clicky-compagnons.json',
    empty: () => {'profil': <String>[], 'compagnons': <dynamic>[]},
    decode: (j) => j is Map ? j.cast<String, dynamic>() : {'profil': <String>[], 'compagnons': <dynamic>[]},
    encode: (v) => v,
  );

  List<String> get profile => [for (final x in (_file.value['profil'] as List?) ?? const []) '$x'];
  bool get hasProfile => profile.where((p) => p.trim().isNotEmpty).isNotEmpty;

  List<Buddy> get all => [
    for (final x in (_file.value['compagnons'] as List?) ?? const [])
      if (x is Map) Buddy.fromJson(x.cast<String, dynamic>()),
  ];

  List<Buddy> get proposals => all.where((b) => b.status == 'propose').toList();
  List<Buddy> get active => all.where((b) => b.status != 'propose' && b.status != 'refuse').toList();
  int get working => all.where((b) => b.working).length;

  bool proposing = false;
  String? error;

  Future<void> load() async {
    if (await _file.reload()) notifyListeners();
  }

  Future<void> saveProfile(List<String> answers) async {
    await _file.update((v) => {...v, 'profil': answers});
    notifyListeners();
  }

  Future<void> _save(Buddy b) async {
    await _file.update((v) {
      final list = [for (final x in (v['compagnons'] as List?) ?? const []) x];
      final i = list.indexWhere((x) => x is Map && x['id'] == b.id);
      i >= 0 ? list[i] = b.toJson() : list.add(b.toJson());
      return {...v, 'compagnons': list};
    });
    notifyListeners();
  }

  Future<void> remove(Buddy b) async {
    await _file.update((v) {
      final list = [for (final x in (v['compagnons'] as List?) ?? const []) if (!(x is Map && x['id'] == b.id)) x];
      return {...v, 'compagnons': list};
    });
    if (b.daily) await Routines.instance.remove('compagnon-${b.id}');
    notifyListeners();
  }

  String get _profileText {
    final p = profile;
    return [
      for (var i = 0; i < questions.length && i < p.length; i++)
        if (p[i].trim().isNotEmpty) '- ${questions[i]} → ${p[i].trim()}',
    ].join('\n');
  }

  /// Demande à l'IA trois compagnons utiles pour cette personne.
  Future<void> propose() async {
    final run = runner;
    if (run == null || proposing) return;
    proposing = true;
    error = null;
    notifyListeners();
    try {
      final raw = await run('''
Propose 3 « compagnons » : de petits agents qui feraient chacun une tâche concrète et vraiment utile pour la personne, sans qu'elle le demande, avec les outils dont tu disposes (recherche internet, agenda, devoirs, notes et messages École Directe, mails, musique, carnet, ordinateur avec permission). Pense à ses cours, contrôles et devoirs à venir (regarde-les avec les outils), à ses objectifs et à ce qui l'embête.

Ce que la personne a répondu :
$_profileText

Réponds UNIQUEMENT par un tableau JSON, sans texte autour :
[{"nom":"Radar Devoirs","mission":"Je vais … (une phrase, à la première personne, concrète)","detail":"pourquoi c'est utile et ce que tu vas faire exactement, 1 ou 2 phrases","chaque_jour":false,"consignes":"les consignes complètes pour faire la tâche et le compte rendu attendu"}]
Les noms : courts, sympas, en français. Au moins un compagnon peut recommencer chaque jour ("chaque_jour": true).''');
      final list = Buddy.parseProposals(raw);
      if (list.isEmpty) throw 'Je n\'ai pas réussi à imaginer de compagnons cette fois. Réessaie.';
      for (final b in list) {
        await _save(b);
      }
    } catch (e) {
      error = '$e';
    } finally {
      proposing = false;
      notifyListeners();
    }
  }

  /// « Ajuster » : le compagnon modifie sa mission selon ta remarque.
  Future<void> adjust(Buddy b, String remark) async {
    final run = runner;
    if (run == null || remark.trim().isEmpty) return;
    b.status = 'propose';
    final raw = await run('''
Voici un compagnon proposé : ${jsonEncode({'nom': b.name, 'mission': b.mission, 'detail': b.detail, 'chaque_jour': b.daily, 'consignes': b.prompt})}
La personne demande de l'ajuster : « ${remark.trim()} ».
Réponds UNIQUEMENT par un tableau JSON d'un seul élément, même format (nom, mission, detail, chaque_jour, consignes).''');
    final next = Buddy.parseProposals(raw).firstOrNull;
    if (next == null) throw 'Je n\'ai pas compris l\'ajustement, reformule.';
    b
      ..name = next.name
      ..mission = next.mission
      ..detail = next.detail
      ..prompt = next.prompt
      ..daily = next.daily;
    await _save(b);
  }

  Future<void> reject(Buddy b) async {
    b.status = 'refuse';
    await _save(b);
  }

  final _stopped = <String>{};

  /// « Arrêter » : le résultat sera ignoré, et la tâche quotidienne coupée.
  Future<void> stop(Buddy b) async {
    _stopped.add(b.id);
    b.status = 'arrete';
    b.result = 'Arrêté.';
    await _save(b);
    if (b.daily) await Routines.instance.remove('compagnon-${b.id}');
  }

  /// « Oui, fais-le » : le compagnon se met au travail (et revient chaque
  /// jour si c'est un compagnon quotidien).
  Future<void> accept(Buddy b) async {
    final run = runner;
    if (run == null) return;
    _stopped.remove(b.id);
    b
      ..status = 'travail'
      ..result = ''
      ..at = DateTime.now();
    await _save(b);
    if (b.daily) {
      await Routines.instance.save(
        Routine(
          id: 'compagnon-${b.id}',
          name: b.name,
          prompt: _task(b),
          hour: 8,
          minute: 5 + (b.id.hashCode.abs() % 40),
          speak: false,
        ),
      );
    }
    try {
      final r = await run(_task(b));
      if (_stopped.contains(b.id)) return;
      b
        ..status = 'fini'
        ..result = r.trim()
        ..at = DateTime.now();
      await _save(b);
      onDone?.call('${b.name} a fini', r.trim());
    } catch (e) {
      if (_stopped.contains(b.id)) return;
      b
        ..status = 'echec'
        ..result = '$e';
      await _save(b);
    }
  }

  String _task(Buddy b) =>
      'Tu es « ${b.name} », un compagnon de Clicky. Ta mission : ${b.mission}\n${b.detail}\n\nConsignes : ${b.prompt}\n\n'
      'Ce que tu sais de la personne :\n$_profileText\n\n'
      'Fais la tâche jusqu\'au bout avec tes outils, puis termine par un compte rendu clair en français '
      '(ce que tu as trouvé ou fait, et la prochaine étape conseillée).';
}

// ---------------------------------------------------------------------------
// Le petit personnage
// ---------------------------------------------------------------------------

/// Un compagnon : un petit nuage tout doux avec deux yeux « ^^ », qui flotte.
class BuddyBlob extends StatefulWidget {
  const BuddyBlob({super.key, required this.color, this.size = 64, this.busy = false});
  final Color color;
  final double size;

  /// Au travail : il se balance plus vite.
  final bool busy;

  @override
  State<BuddyBlob> createState() => _BuddyBlobState();
}

class _BuddyBlobState extends State<BuddyBlob> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(vsync: this, duration: const Duration(seconds: 3))..repeat();

  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _a,
    builder: (context, _) {
      final t = _a.value * 2 * math.pi * (widget.busy ? 2 : 1);
      return Transform.translate(
        offset: Offset(0, math.sin(t) * widget.size * 0.04),
        child: Transform.rotate(
          angle: widget.busy ? math.sin(t * 1.5) * 0.06 : 0,
          child: CustomPaint(
            size: Size(widget.size, widget.size * 0.78),
            painter: _BlobPainter(widget.color, blink: (_a.value * 7) % 1 < 0.04),
          ),
        ),
      );
    },
  );
}

class _BlobPainter extends CustomPainter {
  _BlobPainter(this.color, {this.blink = false});
  final Color color;
  final bool blink;

  @override
  void paint(Canvas canvas, Size s) {
    final w = s.width, h = s.height;
    final body = Path()
      ..addOval(Rect.fromCircle(center: Offset(w * 0.3, h * 0.5), radius: w * 0.26))
      ..addOval(Rect.fromCircle(center: Offset(w * 0.52, h * 0.36), radius: w * 0.3))
      ..addOval(Rect.fromCircle(center: Offset(w * 0.72, h * 0.52), radius: w * 0.24))
      ..addRRect(RRect.fromRectAndRadius(Rect.fromLTWH(w * 0.08, h * 0.45, w * 0.84, h * 0.45), Radius.circular(w * 0.2)));
    canvas.drawShadow(body, color.withValues(alpha: 0.6), 6, false);
    canvas.drawPath(
      body,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.3, -0.5),
          radius: 1.1,
          colors: [Color.lerp(color, Colors.white, 0.45)!, color, Color.lerp(color, Colors.black, 0.12)!],
          stops: const [0, 0.55, 1],
        ).createShader(Offset.zero & s),
    );
    // Les yeux « ^^ ».
    final eye = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(2, w * 0.055)
      ..strokeCap = StrokeCap.round;
    for (final cx in [w * 0.4, w * 0.62]) {
      final y = h * 0.58;
      if (blink) {
        canvas.drawLine(Offset(cx - w * 0.06, y), Offset(cx + w * 0.06, y), eye);
      } else {
        canvas.drawPath(
          Path()
            ..moveTo(cx - w * 0.065, y + h * 0.03)
            ..lineTo(cx, y - h * 0.05)
            ..lineTo(cx + w * 0.065, y + h * 0.03),
          eye,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_BlobPainter old) => old.color != color || old.blink != blink;
}

// ---------------------------------------------------------------------------
// La page des compagnons
// ---------------------------------------------------------------------------

class BuddiesView extends StatefulWidget {
  const BuddiesView({super.key});

  @override
  State<BuddiesView> createState() => _BuddiesViewState();
}

class _BuddiesViewState extends State<BuddiesView> {
  final b = Buddies.instance;
  final answers = List<String>.filled(Buddies.questions.length, '');
  final input = TextEditingController();
  int question = 0;
  bool editingProfile = false;

  @override
  void initState() {
    super.initState();
    unawaited(b.load());
  }

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  Future<void> _next() async {
    answers[question] = input.text.trim();
    input.clear();
    if (question < Buddies.questions.length - 1) {
      setState(() => question++);
      return;
    }
    await b.saveProfile(answers);
    setState(() {
      editingProfile = false;
      question = 0;
    });
    await b.propose();
  }

  Widget _onboarding(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < Buddies.questions.length; i++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      width: i == question ? 22 : 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: i <= question ? const Color(0xFF8E7CF0) : Colors.grey.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 18),
              Text('Je suis curieux de toi.', style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              Text(
                'Quatre petites questions, pour que mes compagnons te soient vraiment utiles.',
                textAlign: TextAlign.center,
                style: text.bodyMedium,
              ),
              const SizedBox(height: 22),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  BuddyBlob(color: Color(Buddy.palette[question % Buddy.palette.length]), size: 78),
                  const SizedBox(width: 10),
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 350),
                      child: Container(
                        key: ValueKey(question),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFCE3C4),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Text(
                          Buddies.questions[question],
                          style: const TextStyle(color: Color(0xFF3A2A18), fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                controller: input,
                autofocus: true,
                minLines: 1,
                maxLines: 4,
                onSubmitted: (_) => _next(),
                decoration: const InputDecoration(hintText: 'Ou tape ta réponse ici…', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  TextButton(
                    onPressed: () {
                      input.clear();
                      _next();
                    },
                    child: const Text('Passer'),
                  ),
                  const Spacer(),
                  FilledButton.icon(
                    icon: const Icon(Icons.arrow_forward_rounded),
                    label: Text(question < Buddies.questions.length - 1 ? 'Suivant' : 'C\'est parti'),
                    onPressed: _next,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _proposal(BuildContext context, Buddy x) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(left: 16), child: BuddyBlob(color: x.colour, size: 70)),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(x.name, style: text.labelLarge?.copyWith(color: Color.lerp(x.colour, Colors.black, 0.35))),
                  const SizedBox(height: 6),
                  Text(x.mission, style: text.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                  if (x.detail.isNotEmpty) ...[const SizedBox(height: 6), Text(x.detail)],
                  if (x.daily)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        children: [
                          const Icon(Icons.repeat_rounded, size: 16),
                          const SizedBox(width: 6),
                          Text('Chaque jour, tant que le PC est allumé', style: text.labelSmall),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(x.daily ? 'Tu veux que je le fasse chaque jour ?' : 'Tu veux que je le fasse ?', style: text.bodySmall),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.close_rounded, size: 18),
                label: const Text('Non'),
                onPressed: () => b.reject(x),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.tune_rounded, size: 18),
                label: const Text('Ajuster'),
                onPressed: () => _adjust(context, x),
              ),
              FilledButton.icon(
                icon: const Icon(Icons.check_rounded, size: 18),
                label: Text(x.daily ? 'Oui, continue chaque jour' : 'Oui, fais-le'),
                onPressed: () => unawaited(b.accept(x)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _adjust(BuildContext context, Buddy x) async {
    final c = TextEditingController();
    final remark = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Ajuster « ${x.name} »'),
        content: TextField(
          controller: c,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(hintText: 'Ex. : plutôt pour les maths, et seulement le week-end'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(d, c.text), child: const Text('Ajuster')),
        ],
      ),
    );
    if (remark == null || remark.trim().isEmpty) return;
    try {
      await b.adjust(x, remark);
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Widget _worker(BuildContext context, Buddy x) {
    final text = Theme.of(context).textTheme;
    final status = switch (x.status) {
      'travail' => 'Au travail · je réfléchis au plan…',
      'fini' => 'Fini · ${_ago(x.at)}',
      'echec' => 'Bloqué',
      'arrete' => 'Arrêté',
      _ => x.status,
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            BuddyBlob(color: x.colour, size: 46, busy: x.working),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(x.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                  Text(status, style: text.labelSmall),
                  const SizedBox(height: 2),
                  Text(
                    x.result.isNotEmpty ? x.result : x.mission,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall,
                  ),
                ],
              ),
            ),
            if (x.working)
              TextButton(onPressed: () => b.stop(x), child: const Text('Arrêter'))
            else ...[
              IconButton(
                tooltip: 'Relancer',
                icon: const Icon(Icons.replay_rounded),
                onPressed: () => unawaited(b.accept(x)),
              ),
              IconButton(
                tooltip: 'Retirer',
                icon: const Icon(Icons.delete_outline_rounded),
                onPressed: () => b.remove(x),
              ),
            ],
            FilledButton.tonal(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (d) => AlertDialog(
                  icon: BuddyBlob(color: x.colour, size: 56),
                  title: Text(x.name),
                  content: SizedBox(
                    width: 520,
                    child: SingleChildScrollView(
                      child: SelectableText(x.result.isEmpty ? x.mission : x.result),
                    ),
                  ),
                  actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('Fermer'))],
                ),
              ),
              child: const Text('Ouvrir'),
            ),
          ],
        ),
      ),
    );
  }

  static String _ago(DateTime d) {
    final m = DateTime.now().difference(d).inMinutes;
    if (m < 1) return 'à l\'instant';
    if (m < 60) return 'il y a $m min';
    if (m < 60 * 24) return 'il y a ${m ~/ 60} h';
    return 'il y a ${m ~/ (60 * 24)} j';
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: b,
    builder: (context, _) {
      if (!b.hasProfile || editingProfile) return SingleChildScrollView(child: _onboarding(context));
      final text = Theme.of(context).textTheme;
      final props = b.proposals;
      final active = b.active;
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Expanded(child: Text('Mes compagnons', style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800))),
              TextButton.icon(
                icon: const Icon(Icons.edit_note_rounded),
                label: const Text('Mes réponses'),
                onPressed: () => setState(() => editingProfile = true),
              ),
              FilledButton.icon(
                icon: b.proposing
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.auto_awesome_rounded),
                label: const Text('De nouvelles idées'),
                onPressed: b.proposing ? null : b.propose,
              ),
            ],
          ),
          if (b.error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(b.error!, style: const TextStyle(color: Colors.redAccent))),
          if (b.proposing && props.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Column(
                children: [
                  BuddyBlob(color: Color(0xFFB79CF5), size: 80, busy: true),
                  SizedBox(height: 12),
                  Text('Je regarde tes cours, tes devoirs et tes réponses…'),
                ],
              ),
            ),
          if (props.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Ils se proposent', style: text.titleSmall),
            const SizedBox(height: 8),
            for (final x in props) _proposal(context, x),
          ],
          if (active.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Au travail et terminés', style: text.titleSmall),
            const SizedBox(height: 8),
            for (final x in active) _worker(context, x),
          ],
          if (props.isEmpty && active.isEmpty && !b.proposing)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Text('Touche « De nouvelles idées » : mes compagnons vont se proposer.', textAlign: TextAlign.center),
            ),
        ],
      );
    },
  );
}
