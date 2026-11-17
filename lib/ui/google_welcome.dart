import 'package:material_ui/material_ui.dart';

import '../core/google_auth.dart';
import '../core/module_store.dart';
import 'clicky/hud.dart';
import 'google_setup.dart';

/// Clicky demande ton compte Google (une fois par compte Mon Hub) : pour
/// ranger ton Drive, ouvrir et écrire tes Google Docs dans le Word de Mon
/// Hub, et voir ton agenda Google.
class GoogleWelcome {
  GoogleWelcome._();

  static const _seenKey = 'google.welcome.v137';

  /// Il manque un compte Google, ou il n'a que la lecture du Drive (ou la
  /// connexion Google n'est pas encore activée).
  static bool get needed {
    if (!GoogleAuth.available) return true;
    final a = GoogleAuth.driveAccount;
    return a == null || !GoogleAuth.canWriteDrive(a);
  }

  /// La fenêtre elle-même (tests, aperçus).
  static Widget dialog() => const _GoogleWelcomeDialog();

  static Future<void> maybeShow(BuildContext context, {bool force = false}) async {
    if (!needed) return;
    if (!force && ModuleStore.prefs.getBool(_seenKey) == true) return;
    await ModuleStore.prefs.setBool(_seenKey, true);
    if (!context.mounted) return;
    await showDialog<void>(context: context, builder: (_) => const _GoogleWelcomeDialog());
  }
}

class _GoogleWelcomeDialog extends StatefulWidget {
  const _GoogleWelcomeDialog();

  @override
  State<_GoogleWelcomeDialog> createState() => _GoogleWelcomeDialogState();
}

class _GoogleWelcomeDialogState extends State<_GoogleWelcomeDialog> {
  bool busy = false;
  String? done;
  String? error;

  Future<void> _connect() async {
    if (!GoogleAuth.available) {
      // Il faut d'abord activer Google (une fois) : l'écran qui explique.
      final nav = Navigator.of(context);
      nav.pop();
      await nav.push(MaterialPageRoute<void>(builder: (_) => const GoogleSetupPage()));
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final email = await GoogleAuth.signIn();
      // Ce compte sert au Drive et aux Docs.
      await (ModuleStore()..bind('drive')).setJson('account', email);
      setState(() => done = email);
    } catch (e) {
      setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final existing = GoogleAuth.driveAccount;
    final upgrade = existing != null && done == null;
    Widget perk(IconData icon, Color color, String text) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, color: color, size: 19),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: const TextStyle(color: Color(0xFFD5E9F2), height: 1.3))),
        ],
      ),
    );
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 480,
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          gradient: const RadialGradient(
            center: Alignment(0, -0.6),
            radius: 1.3,
            colors: [Color(0xFF0E2236), Color(0xFF060D16)],
          ),
          border: Border.all(color: hudCyan.withValues(alpha: 0.35)),
          boxShadow: [BoxShadow(color: hudCyan.withValues(alpha: 0.18), blurRadius: 40)],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 74,
              height: 74,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(colors: [hudCyan, hudCyan.withValues(alpha: 0.1)]),
                boxShadow: [BoxShadow(color: hudCyan.withValues(alpha: 0.5), blurRadius: 30)],
              ),
              child: Icon(done != null ? Icons.check_rounded : Icons.auto_awesome_rounded, color: Colors.black, size: 34),
            ),
            const SizedBox(height: 18),
            Text(
              done != null
                  ? 'C\'est bon !'
                  : upgrade
                      ? 'Une petite autorisation de plus'
                      : 'Connecte ton compte Google',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            Text(
              done != null
                  ? '$done est connecté. Dis-moi « range mon Drive » ou ouvre un Google Doc dans Documents.'
                  : upgrade
                      ? 'Ton compte $existing est connecté en lecture seule. Autorise-moi aussi à modifier ton Drive :'
                      : !GoogleAuth.available
                          ? 'C\'est Clicky. Active Google une fois (5 minutes, je t\'explique tout) et je pourrai :'
                          : 'C\'est Clicky. Avec ton compte Google, je peux faire beaucoup plus pour toi :',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFFB7D9E6), fontSize: 15, height: 1.45),
            ),
            if (done == null) ...[
              const SizedBox(height: 16),
              perk(Icons.auto_fix_high_rounded, const Color(0xFF34A853), 'Ranger ton Google Drive (par type et par matière)'),
              perk(Icons.description_rounded, const Color(0xFF4285F4), 'Ouvrir et écrire tes Google Docs dans le Word de Mon Hub'),
              perk(Icons.event_rounded, const Color(0xFFFBBC04), 'Voir ton agenda Google avec tes cours'),
              perk(Icons.lock_rounded, hudCyan, 'Tout reste sur ton PC : Mon Hub n\'a aucun serveur'),
            ],
            if (error != null) ...[
              const SizedBox(height: 10),
              Text(error!, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFFFF8A80))),
            ],
            const SizedBox(height: 22),
            if (done != null)
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: hudCyan, foregroundColor: Colors.black),
                onPressed: () => Navigator.pop(context),
                child: const Text('Super'),
              )
            else
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: busy ? null : () => Navigator.pop(context),
                      child: const Text('Plus tard', style: TextStyle(color: Colors.white60)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.black87,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      icon: busy
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('G', style: TextStyle(color: Color(0xFF4285F4), fontWeight: FontWeight.w900, fontSize: 18)),
                      label: Text(
                        busy
                            ? 'Termine dans ton navigateur…'
                            : !GoogleAuth.available
                                ? 'Activer Google'
                                : (upgrade ? 'Autoriser' : 'Se connecter avec Google'),
                      ),
                      onPressed: busy ? null : _connect,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
