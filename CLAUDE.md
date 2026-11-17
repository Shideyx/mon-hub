# Mon Hub — notes pour Claude

## Livraison (important)
- La personne installe Mon Hub sur Windows et **reçoit les mises à jour automatiquement** :
  chaque push sur `main` lance `.github/workflows/build.yml`, qui publie une release GitHub,
  et l'appli se met à jour toute seule (`lib/core/updater.dart`).
- Donc, quand un changement est fini, testé (`flutter analyze`, `flutter test`) et poussé sur la
  branche de travail : **ouvrir la pull request vers `main` et la fusionner** sans attendre
  qu'on le redemande. Sinon la correction n'arrive jamais sur son PC.
- Réponses et messages de commit en français, simples (la personne n'est pas développeuse).

## Repères
- Flutter (Dart). Clicky = l'assistant IA : `lib/ui/clicky/`.
- Micro Windows : `SmartEars` (`whisper.dart`) choisit Windows ou Whisper (whisper.cpp v1.8.2 +
  modèle ggml, dans %APPDATA%\MonHub\whisper, enregistrement avec le paquet `record`).
  Reconnaissance Windows : `ears.dart` (PowerShell lancé en `detachedWithStdio` : ne jamais lire
  `exitCode` d'un processus détaché, ça lève « Bad state: Process is detached »).
- Outils de Clicky lui-même (`ClickyController.localTools`) : réparation du micro
  (`clicky_diagnostic`, `clicky_reparer_micro`) et contrôle du PC (`pc.dart` : `pc_commande`,
  `pc_ouvrir`, `pc_lire`, `pc_ecrire_fichier`). Servis aussi à Claude Code via le pont local
  (`ClaudeBridge.appTools`). Permission : `ClaudeBridge.isWriteAction` + `confirmAction`.
- Vie privée : **aucun serveur à nous**, toutes les données restent sur l'appareil. Ne jamais
  ajouter d'envoi de données vers un serveur du créateur (statistiques, journaux…). Données
  locales : JsonFile chiffré via `lib/core/vault.dart` ; secrets : `ModuleStore.writeSecret`.
- École Directe : API non officielle (`ed_client.dart`), décodage des messages dans
  `EdClient.decodeContent` / `htmlToText` ; cloud : `EdClient.cloud`.
- Clicky agit (`act.dart` + `ClickyController.act`) : boucle capture → action JSON → exécution
  (`Win.glide/click/drag/windowList/windowAction`), déclenchée par `[AGIR]…[/AGIR]` ou « prends la
  main ». Compagnons : `buddies.dart`. Voix : une seule à la fois (`VoiceLock`).
- Spotify : depuis février 2026, appli en mode développement = Premium du créateur obligatoire,
  `/me/library` pour les j'aime, plus de « top tracks » ; sans API → recherche Deezer + `spotify:search:`.
- Réponse instantanée : Gemini Live (`live.dart`, WebSocket BidiGenerateContent, activité manuelle
  activityStart/End, audio PCM 16 kHz → 24 kHz joué par `PcmPlayer` waveOut). Branché dans
  `ClickyController.startListening/stopListening/ask` (`liveReady`). Erreurs : `ErrorLog`
  (`journal-erreurs.log`), Clicky partout surveillé par `ClickyDesktop.watch()`.
- Voix de Windows (flutter_tts) **retirée** à la demande de la personne (et elle faisait planter :
  `FlutterTts.stop()` à vide). Ne pas la remettre. Voix : Microsoft (Edge) ou Gemini ; sans internet,
  réponse écrite.
- Certificats https : `TrustedCertificates.install()` (magasins Windows ROOT + CA, et
  `assets/cacert.pem` de Mozilla) au démarrage des deux programmes.
