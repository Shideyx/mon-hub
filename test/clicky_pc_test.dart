import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/claude_bridge.dart';
import 'package:hub/ui/clicky/pc.dart';

void main() {
  test('contrôle du PC : outils et permissions', () {
    final tools = PcControl.tools();
    expect(tools.map((t) => t.name), containsAll(['pc_commande', 'pc_ouvrir', 'pc_lire', 'pc_ecrire_fichier']));
    // Commandes et écritures : permission ; lire et ouvrir : non.
    bool write(String n) => ClaudeBridge.isWriteAction(tools.firstWhere((t) => t.name == n));
    expect(write('pc_commande'), isTrue);
    expect(write('pc_ecrire_fichier'), isTrue);
    expect(write('pc_lire'), isFalse);
    expect(write('pc_ouvrir'), isFalse);
  });

  test('commandes dangereuses : toujours demandées', () {
    for (final c in [
      'Format-Volume -DriveLetter D',
      'format D: /q',
      'diskpart /s x.txt',
      'Remove-Item -Recurse -Force C:\\Users\\moi\\Documents',
      'rm -rf ~/photos',
      'rd /s /q C:\\Temp',
      'reg delete HKLM\\Software\\X /f',
      'Stop-Computer -Force',
      'shutdown /s /t 0',
    ]) {
      expect(PcControl.dangerous(c), isTrue, reason: c);
    }
    for (final c in [
      'winget install --id VideoLAN.VLC -e --accept-package-agreements --accept-source-agreements',
      'Get-ChildItem ~\\Downloads',
      'Remove-Item C:\\Temp\\vieux.txt',
      'Start-Process notepad',
      'Get-PSDrive C',
    ]) {
      expect(PcControl.dangerous(c), isFalse, reason: c);
    }
  });

  test('script PowerShell : sortie UTF-8 et erreurs incluses', () {
    final s = PcControl.psScript('Get-Date');
    expect(s, contains('Get-Date'));
    expect(s, contains('UTF8'));
    expect(s, contains('2>&1'));
  });

  test('« ~ » = dossier de la personne', () {
    final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '';
    expect(PcControl.expand('~/x.txt'), '$home/x.txt');
  });

  test('lance une vraie commande, lit et écrit des fichiers', () async {
    if (Platform.isWindows) return;
    final r = await PcControl.run('echo bonjour; exit 3');
    expect(r['sortie'], 'bonjour');
    expect(r['code'], 3);
    final slow = await PcControl.run('sleep 5', timeout: const Duration(milliseconds: 300));
    expect(slow['arretee'], isNotNull);
    final dir = await Directory.systemTemp.createTemp('pc-test');
    addTearDown(() => dir.delete(recursive: true));
    final f = '${dir.path}/note.txt';
    await PcControl.write(f, 'a');
    await PcControl.write(f, 'b', append: true);
    expect((await PcControl.read(f) as Map)['contenu'], 'ab');
    expect((await PcControl.read(dir.path) as Map)['elements'], ['note.txt']);
    expect(() => PcControl.run('true', cwd: '${dir.path}/absent'), throwsA(isA<String>()));
  });
}
