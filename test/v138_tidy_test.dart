import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/google_auth.dart';
import 'package:hub/core/hub_files.dart';
import 'package:hub/core/module_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hub/core/tidy.dart';
import 'package:hub/modules/drive/drive_tidy.dart';

void main() {
  test('ranger un dossier : par type, par matière, doublons à part, puis tout annuler', () async {
    final root = Directory.systemTemp.createTempSync('tidy');
    final data = Directory.systemTemp.createTempSync('tidydata');
    HubFiles.overrideRoot = data.path;
    final sep = Platform.pathSeparator;
    final old = DateTime.now().subtract(const Duration(hours: 2));
    void file(String name, String content, {bool recent = false}) {
      final f = File('${root.path}$sep$name')..writeAsStringSync(content);
      if (!recent) f.setLastModifiedSync(old);
    }

    file('vacances.jpg', 'image');
    file('DM_maths_chapitre3.pdf', 'pdf maths');
    file('dissertation_philo.docx', 'philo');
    file('setup_minecraft.exe', 'exe');
    file('notes.txt', 'notes');
    file('bizarre.xyz', 'x');
    file('vacances (1).jpg', 'image'); // même contenu que vacances.jpg
    file('Raccourci Roblox.lnk', 'lnk');
    file('en_cours.crdownload', 'dl');
    file('tout_neuf.png', 'neuf', recent: true);
    Directory('${root.path}${sep}Déjà là').createSync();
    try {
      final plan = await PcTidy.analyze(root);
      final where = {for (final m in plan.moves) m.name: m.dest};
      expect(where['vacances.jpg'], 'Images');
      expect(where['DM_maths_chapitre3.pdf'], 'Cours${sep}Maths');
      expect(where['dissertation_philo.docx'], 'Cours${sep}Philosophie');
      expect(where['setup_minecraft.exe'], 'Programmes');
      expect(where['notes.txt'], 'Documents');
      expect(where['bizarre.xyz'], 'Autres');
      expect(where['vacances (1).jpg'], 'Doublons');
      // Raccourcis, téléchargements en cours, fichiers tout récents : on ne
      // touche pas.
      expect(where.containsKey('Raccourci Roblox.lnk'), isFalse);
      expect(where.containsKey('en_cours.crdownload'), isFalse);
      expect(where.containsKey('tout_neuf.png'), isFalse);
      expect(plan.skipped, 3);

      final (n, errors) = await PcTidy.apply(plan);
      expect(errors, isEmpty);
      expect(n, 7);
      expect(File('${root.path}${sep}Cours${sep}Maths${sep}DM_maths_chapitre3.pdf').existsSync(), isTrue);
      expect(File('${root.path}${sep}Images${sep}vacances.jpg').existsSync(), isTrue);
      expect(File('${root.path}${sep}vacances.jpg').existsSync(), isFalse);
      expect(Directory('${root.path}${sep}Déjà là').existsSync(), isTrue);

      // Annuler : tout revient, les dossiers créés disparaissent.
      expect(await PcTidy.undoLast(), 7);
      expect(File('${root.path}${sep}vacances.jpg').existsSync(), isTrue);
      expect(File('${root.path}${sep}DM_maths_chapitre3.pdf').existsSync(), isTrue);
      expect(Directory('${root.path}${sep}Images').existsSync(), isFalse);
      expect(Directory('${root.path}${sep}Cours').existsSync(), isFalse);
      expect(await PcTidy.undoLast(), 0);
    } finally {
      HubFiles.overrideRoot = null;
    }
  });

  test('nom libre si le fichier existe déjà, matières dans les noms', () {
    final d = Directory.systemTemp.createTempSync('free');
    File('${d.path}${Platform.pathSeparator}photo.jpg').writeAsStringSync('a');
    expect(PcTidy.freeName(d, 'photo.jpg'), 'photo (2).jpg');
    expect(PcTidy.freeName(d, 'autre.jpg'), 'autre.jpg');
    expect(PcTidy.subject('Exposé_Histoire-géo_guerre froide.pptx'), 'Histoire-Géo');
    expect(PcTidy.subject('TP_physique_chimie.pdf'), 'Physique-Chimie');
    expect(PcTidy.subject('photo_all.jpg'), isNull);
  });

  test('connexion Google : l\'identifiant client se colle dans Mon Hub', () async {
    SharedPreferences.setMockInitialValues({});
    await ModuleStore.init();
    expect(GoogleAuth.available, isFalse);
    expect(() => GoogleAuth.setClient('n\'importe quoi', 'x'), throwsA(isA<String>()));
    await GoogleAuth.setClient(' 123-abc.apps.googleusercontent.com ', ' GOCSPX-secret ');
    expect(GoogleAuth.available, isTrue);
    expect(GoogleAuth.clientId, '123-abc.apps.googleusercontent.com');
    expect(GoogleAuth.clientSecret, 'GOCSPX-secret');
    await GoogleAuth.setClient('', '');
    expect(GoogleAuth.available, isFalse);
  });

  test('Drive : chaque type de fichier a son dossier', () {
    expect(DriveTidy.categoryOf('application/vnd.google-apps.document', 'x'), 'Documents');
    expect(DriveTidy.categoryOf('application/pdf', 'x.pdf'), 'PDF');
    expect(DriveTidy.categoryOf('image/jpeg', 'IMG.jpg'), 'Photos');
    expect(DriveTidy.categoryOf('application/zip', 'a.zip'), 'Archives');
    expect(DriveTidy.categoryOf('application/octet-stream', 'truc'), 'Autres');
  });
}
