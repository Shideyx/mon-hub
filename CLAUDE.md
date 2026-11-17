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
- **Une seule voix : Gemini** (demande de la personne, v1.43). Voix de Windows (flutter_tts) et voix Microsoft (Edge)
  **retirées, ne pas les remettre**. `ClickyVoice` (`voice.dart`) : synthèse `GeminiVoice` par **gros morceaux**
  (`ClickyVoice.chunks/cutAt` : quota gratuit ~15 lectures/jour), relais `LiveReader` (Gemini Live, même voix) quand
  le quota est épuisé ; sans clé ni internet : réponse écrite. Les briefings/topos sont **toujours lus**
  (`presentTopo` → `speak(force: true)`).
- Certificats https : `TrustedCertificates.install()` (magasins Windows ROOT + CA, et
  `assets/cacert.pem` de Mozilla) au démarrage des deux programmes.
- Look : la personne **préfère l'ancienne interface** (violet, en-tête dégradé, cartes arrondies) ; le look
  Windows 11 de la v1.34 a été retiré en v1.35, ne pas le remettre. `core/windows_look.dart` ne sert plus
  qu'aux fenêtres des widgets détachés (barre de titre).
  Liens web : `core/browser.dart` (Chrome par défaut). Widgets détachés : `core/desktop_widgets.dart`,
  `ui/widget_window.dart`, lanceur `windows/runner/main.cpp` (`--widget=`, AppUserModelID par widget ;
  le runner compile en /W4 /WX : aucun avertissement C++ toléré). Appels : `ui/call_page.dart`.
- Accueil : les résumés des cartes ne sont **pas des listes** (la personne n'aime pas) : `ui/summary.dart`
  (`NextUpSummary` prochain cours en grand + pastilles, `ChatsSummary` visages + bulle, `SummaryFace`,
  `StatTile`).
- Discord : serveurs/salons (`DiscordApi.guilds/channels`, `DiscordChannel.grouped`) ; appels sans
  navigateur = `discord_phone.dart` : le Discord officiel (discord.com) caché derrière Mon Hub
  (`DiscordPhoneLayer` dans le builder de `HubApp`, enfants du Stack **avec clés** pour ne jamais
  reconstruire l'appli), sonnerie détectée dans la page (`statusScript`), boutons pressés par
  `buttonScript`. Seule la fenêtre principale l'ouvre (`DiscordPhone.allowed`).
- YouTube : `modules/youtube/` = le vrai youtube.com dans `HubWebView`, recherche sans clé
  (`ytInitialData`, cookie `SOCS=CAI`), historique « Reprendre » local.
- IA simple sans outils (corriger, résumer, faire des cartes) : `core/ai_text.dart` (`AiText.ask` : clé Gemini
  d'abord — lit photos et PDF —, sinon le cerveau de Clicky ; `AiText.json` ; `AiText.override` pour les tests).
- Documents = **le vrai Google Docs** (la personne ne veut pas d'éditeur maison) : `modules/docs/docs_module.dart`
  ouvre docs.google.com dans `HubWebView` ; `GoogleDocs` (API Drive/Docs) pour Clicky (`doc_creer` Markdown →
  .docx converti en Google Doc, `doc_lire` export texte, `doc_ecrire` via Docs API batchUpdate, `doc_exporter`).
  `DocFormat` (Delta ↔ Markdown ↔ .docx) sert à ces conversions ; `DocStore` = anciens documents v1.37 (bandeau
  pour les envoyer sur Google Docs ou en .docx). flutter_quill et pdf retirés.
- Révisions : `modules/revisions/` (FSRS-5 dans `fsrs.dart`, `RevisionsStore`, quiz/écrire/associer/minuteur,
  cartes faites par l'IA, plan avant les contrôles ED dans l'agenda).
- Google : portée `drive` complète (ranger le Drive, Google Docs) ; les comptes connectés avant la v1.37 n'ont
  que la lecture → `GoogleAuth.canWriteDrive` / reconnexion.
- Rangement : `core/tidy.dart` (`PcTidy` : fichiers en vrac → type ou Cours/matière, doublons dans « Doublons »,
  jamais de suppression, journal `rangement-*.json` pour annuler), `modules/drive/drive_tidy.dart` (Drive),
  écran `ui/tidy_page.dart` (Réglages → Rangement). Outils `pc_ranger_apercu/pc_ranger/pc_ranger_annuler`,
  `drive_ranger_*` (« ranger » = action à autoriser dans `ClaudeBridge.isWriteAction` et `PcControl.isWrite`).
- Compte Google demandé par Clicky après la visite guidée (et une fois aux anciens comptes) : `ui/google_welcome.dart`.
- ⚠️ Les secrets GitHub GOOGLE_CLIENT_ID/SECRET étaient **vides** (journal de construction v1.37) : la connexion
  Google s'active dans l'appli (Réglages → Connexion Google, `ui/google_setup.dart` : 5 liens directs dont
  `flows/enableapi` pour toutes les API, puis le fichier JSON « Application de bureau » ; `GoogleAuth.setClient`).
  Une fois les secrets GitHub remplis, chaque utilisateur se connecte en un clic (l'ID de construction prime).
- Réponses **sans IA** d'abord (demande de la personne : limiter Claude) : `ui/clicky/quick.dart` (`QuickAnswers` :
  heure, date, calculs `Calc`, minuteur/rappel, son, musique, devoirs, contrôle, emploi du temps, notes, météo,
  révisions, ranger, YouTube, document, liste, ouvrir) branché dans `ClickyController.ask` (`_handleQuick`, réglage
  `quick`). Phrases reconnues **entières** (tests : les vraies questions doivent partir vers l'IA). Ajouter ici
  tout ce qu'un algorithme sait faire.
- Contrôles : `RevisionsModule.autoPrepare` (dans `poll`) prépare tout seul fiche + cartes + quiz (un paquet
  `📝 Matière`, `Deck.sheet/quiz/testId`), une fois par contrôle (`testKey`), réglage `autoPrep`. Fiche : `fiche_view.dart`.
- Widgets du bureau : `DesktopWidgets.inWidgetWindow` ; `HubModule.liveWidget` (pas de rechargement toutes les
  3 min) ; YouTube y est le vrai m.youtube.com (`YouTubeMini`) et une vidéo ouverte y passe en grand (`MiniVideoView`).
- YouTube « petit écran » (`YouTubeMiniPlayer`) : la vidéo se joue **dans la carte YouTube de l'accueil** (`_CardVideo`,
  `inCard`), sinon dans une petite fenêtre flottante (`YouTubeMiniLayer`) ; en quittant la page pendant une vidéo, elle
  continue à la même seconde (`VideoState`). `MiniVideoView` = watch?v=…&t= + CSS qui ne garde que le lecteur.
- Bouton « Menu » toujours visible hors de l'accueil + Alt + Début : `core/hub_home.dart` (`HubHome.go` ferme pages,
  boîtes, fenêtre d'appel Discord ; `HubHomeLayer` ; observateur du Navigator). Les couches au-dessus du Navigator
  (`HubHomeLayer`, `YouTubeMiniLayer`, `AssistantLayer`) n'ont **pas d'infobulles** (pas d'Overlay).
- Animations façon Spotify : `ui/motion.dart` (`SpotifyPageTransitionsBuilder` dans le thème, `EnterAnimation` cartes
  en cascade, `PressScale`/`NoPressZone`, `EqualizerBars`, `ShimmerLines` dans `LoadingHint`). Rien qui tourne en
  boucle sans raison (fluidité).
- Médias : `ui/media_view.dart` (`WebVideo` = vidéo MP4 lue par WebView2, sans paquet ; `MediaViewer` plein écran ;
  `MediaThumb`). Vocaux : `VoiceNotePlayer` télécharge d'abord le son (`DeviceFileSource`), sinon `WebAudio`.
- Instagram = **le vrai instagram.com** dans Mon Hub (`InstagramPage`/`InstagramMini`, `HubWebView`), v1.42.
  ⚠️ **Jamais d'API privée Instagram ni de requête automatique** (lecture des messages, envoi, notifications) :
  l'ancienne version (se faisant passer pour l'appli Android + relève toutes les 2 min) a fait bloquer le compte
  de la personne (« logiciel malveillant »). Non lus = titre de la page (« (3) Instagram »). Discord : conversation façon
  Discord (`_DiscordLine`, messages regroupés, `_DaySeparator`, `DiscordEmbed`, vidéos).
- Assistant personnel (proactif, avec accord) : `ui/clicky/assistant.dart` (`Assistant` : consentement + 8 automatismes
  `AssistantFeature.all`, tour toutes les 5 min `tick`, propositions `Proposal` affichées par `AssistantLayer` en bas à
  gauche, `ui/clicky/assistant_view.dart` ; Réglages → Assistant personnel = `AssistantPage`). Initiatives hors modules :
  `ui/clicky/initiatives.dart` (`DateSpotter` : rendez-vous / dates limites dans les messages, `grade20`), notes,
  série de révisions, messages sans réponse, pluie, objectifs (`Carnet` liste `goals`), idées Gemini 1×/jour
  (`AiText.ask(geminiOnly: true)`, jamais Claude). Briefing du matin = `Assistant.morningBriefing` (sans IA, Gemini pour
  rédiger) : routine topo-matin et commande « briefing ». Outils `assistant_*` dans `ClickyController.localTools`.
- Appli qui fige (v1.41) : **jamais** de `FutureBuilder(future: x.load())` dont `load()` prévient les écouteurs sans
  changement (`JsonFile.reload()` dit si le fichier a changé) ; le résumé d'une carte d'accueil est gardé au survol
  (`_ModuleCardState._summary`) ; le Discord caché est rendu invisible (`DiscordPhone.quietScript`) ; chiffrement et
  gros JSON hors du fil de l'interface (`Vault`, `JsonFile.load` avec `Isolate.run`).
