import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Lance les petits scripts PowerShell de Mon Hub **sans fichier .ps1** :
/// le script passe directement en paramètre (`-EncodedCommand`). Certains
/// PC bloquent les fichiers de script (règles de sécurité, antivirus) : le
/// micro, la musique en cours, le mot d'activation et la lecture d'écran
/// marchent quand même.
class PowerShell {
  PowerShell._();

  /// Remplace la première ligne `param(...)` du script par des variables.
  static String withParams(String script, Map<String, String> params) {
    final body = script.replaceFirst(RegExp(r'^\s*param\([^\n]*\)\s*\n'), '');
    final head = [for (final e in params.entries) "\$${e.key} = '${e.value.replaceAll("'", "''")}'"];
    return '${head.join('\n')}\n$body';
  }

  /// Script encodé pour `-EncodedCommand` (UTF-16 petit-boutiste, base64).
  static String encode(String script) {
    final units = script.codeUnits;
    final bytes = Uint8List(units.length * 2);
    for (var i = 0; i < units.length; i++) {
      bytes[i * 2] = units[i] & 0xFF;
      bytes[i * 2 + 1] = units[i] >> 8;
    }
    return base64Encode(bytes);
  }

  static List<String> args(String script, Map<String, String> params) => [
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass',
    '-EncodedCommand',
    encode(withParams(script, params)),
  ];

  /// Lance un script qui reste ouvert (entrées / sorties branchées).
  static Future<Process> start(String script, [Map<String, String> params = const {}]) =>
      Process.start('powershell.exe', args(script, params), mode: ProcessStartMode.detachedWithStdio);

  /// Lance un script et attend sa réponse.
  static Future<ProcessResult> run(
    String script, [
    Map<String, String> params = const {},
    Duration timeout = const Duration(seconds: 25),
  ]) =>
      Process.run('powershell.exe', args(script, params), stdoutEncoding: utf8, stderrEncoding: utf8).timeout(timeout);

  /// Première ligne utile d'une erreur PowerShell (pour l'afficher).
  static String firstError(String stderr) {
    final lines = stderr
        .split(RegExp(r'[\r\n]+'))
        .map((l) => l.trim())
        .where(
          (l) =>
              l.isNotEmpty &&
              !l.startsWith('+') &&
              !l.startsWith('At ') &&
              !l.startsWith('Au caract') &&
              !l.startsWith('#< CLIXML'),
        )
        .toList();
    if (lines.isEmpty) return '';
    final l = lines.first;
    return l.length > 220 ? '${l.substring(0, 217)}…' : l;
  }
}
