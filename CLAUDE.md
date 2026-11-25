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
- Flutter (Dart). Nexo = l'assistant IA : `lib/ui/clicky/`.
- Micro Windows : `SmartEars` (`whisper.dart`) choisit Windows ou Whisper (whisper.cpp v1.8.2 +
  modèle ggml, dans %APPDATA%\MonHub\whisper, enregistrement avec le paquet `record`).
  Reconnaissance Windows : `ears.dart` (PowerShell lancé en `detachedWithStdio` : ne jamais lire
  `exitCode` d'un processus détaché, ça lève « Bad state: Process is detached »).
- Outils de Nexo lui-même (`ClickyController.localTools`) : réparation du micro
  (`clicky_diagnostic`, `clicky_reparer_micro`) et contrôle du PC (`pc.dart` : `pc_commande`,
  `pc_ouvrir`, `pc_lire`, `pc_ecrire_fichier`). Servis aussi à Claude Code via le pont local
  (`ClaudeBridge.appTools`). Permission : `ClaudeBridge.isWriteAction` + `confirmAction`.
- Vie privée : **aucun serveur à nous** (Mon Hub en ligne = le projet Supabase **de la personne**, voir v1.60),
  données perso sur l'appareil. Ne jamais ajouter d'envoi de données vers un serveur du créateur (statistiques,
  journaux…). Données
  locales : JsonFile chiffré via `lib/core/vault.dart` ; secrets : `ModuleStore.writeSecret`.
- École Directe : API non officielle (`ed_client.dart`), décodage des messages dans
  `EdClient.decodeContent` / `htmlToText` ; cloud : `EdClient.cloud`.
- Nexo agit (`act.dart` + `ClickyController.act`) : boucle capture → action JSON → exécution
  (`Win.glide/click/drag/windowList/windowAction`), déclenchée par `[AGIR]…[/AGIR]` ou « prends la
  main ». Compagnons : `buddies.dart`. Voix : une seule à la fois (`VoiceLock`).
- Spotify : depuis février 2026, appli en mode développement = Premium du créateur obligatoire,
  `/me/library` pour les j'aime, plus de « top tracks » ; sans API → recherche Deezer + `spotify:search:`.
- Réponse instantanée : Gemini Live (`live.dart`, WebSocket BidiGenerateContent, activité manuelle
  activityStart/End, audio PCM 16 kHz → 24 kHz joué par `PcmPlayer` waveOut). Branché dans
  `ClickyController.startListening/stopListening/ask` (`liveReady`). Erreurs : `ErrorLog`
  (`journal-erreurs.log`), Nexo partout surveillé par `ClickyDesktop.watch()`.
- **Une seule voix : Gemini** (demande de la personne, v1.43). Voix de Windows (flutter_tts) et voix Microsoft (Edge)
  **retirées, ne pas les remettre**. `ClickyVoice` (`voice.dart`) : synthèse `GeminiVoice` par **gros morceaux**
  (`ClickyVoice.chunks/cutAt` : quota gratuit ~15 lectures/jour), relais `LiveReader` (Gemini Live, même voix) quand
  le quota est épuisé ; sans clé ni internet : **la voix du PC (Piper)** depuis la v1.68 (voir plus bas), sinon réponse
  écrite. Les briefings/topos sont **toujours lus** (`presentTopo` → `speak(force: true)`).
- Certificats https : `TrustedCertificates.install()` (magasins Windows ROOT + CA, et
  `assets/cacert.pem` de Mozilla) au démarrage des deux programmes.
- Look : **interface HUD (v1.60, validée par la personne sur maquette)** : mêmes couleurs (violet #7C5CFF, rose
  #E0457B, fond sombre), coins coupés, boutons penchés, rayures, chevrons, hexagones ; titres Chakra Petch, étiquettes
  JetBrains Mono (`assets/fonts`, OFL). Kit : `ui/hud/hud.dart` (`HudColors.of`, `HudPanel`, `HudButton`, `SlantBorder`,
  `hudCut`, `HudTag`, `HexAvatar`, `Hatch`, `SegBar`, `Barcode`, `Chevrons`, `HudBackground`). **Rien qui fasse
  « IA / Gemini »** (pas de bordure en dégradé brillant) : la barre de Nexo est une console (onglet CLICKY + `>_`).
  Le look Windows 11 de la v1.34 a été retiré en v1.35, ne pas le remettre. `core/windows_look.dart` ne sert plus
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
  d'abord — lit photos et PDF —, sinon le cerveau de Nexo ; `AiText.json` ; `AiText.override` pour les tests).
- Documents = **le vrai Google Docs** (la personne ne veut pas d'éditeur maison) : `modules/docs/docs_module.dart`
  ouvre docs.google.com dans `HubWebView` ; `GoogleDocs` (API Drive/Docs) pour Nexo (`doc_creer` Markdown →
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
- Compte Google demandé par Nexo après la visite guidée (et une fois aux anciens comptes) : `ui/google_welcome.dart`.
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
- Nexo « conscient » façon heyclicky/JARVIS (v1.44) : `ui/clicky/mind.dart` (`ClickyMind` : humeur `moodAt`, lien `bond`,
  souvenirs `Episode` — conversation, émotion, **attente** = « j'ai un oral jeudi » repéré par `DateSpotter`, il prend des
  nouvelles ensuite (`dueLoops`, salutation) —, `promptBlock` dans les consignes Claude et Gemini Live, `selfAnswer` sans IA
  (« ça va ? », « es-tu conscient ? » → honnête : simulation), `thought` (pensées par règles), quotas voix 4/j et remarques
  8/j). Réglages → Conscience de Nexo (`mind_page.dart`). Persona heyclicky dans `clickyPersona` (hud.dart).
- Présence : `ClickyController._presenceTick` (toutes les 2 s) : regards autour quand la souris ne bouge plus (`glance`,
  `gaze/gazeNote`, `lookSpots` = fenêtre au premier plan, horloge, autre écran), remarques spontanées `noticeSomething`
  (Gemini vision, jamais Claude ; jamais en plein écran `Win.foregroundFullscreen`, ni sur `privateApp`, ni sur Mon Hub),
  `think()` (rappels de l'assistant dits par Nexo ; `think64`/`notice` envoyés à Nexo partout). Vol = `flight.dart`
  (`ClickyFlight` : arc, 0,26–0,75 s selon la distance, orientation `angleAt`, taille 1,3 au milieu ; `springTowards` pour
  suivre la souris), `flightPose` ; il parcourt la fenêtre pendant qu'il réfléchit (`_scanStep`) et part vers la cible
  avant de viser précisément. Bulle qui rebondit et s'écrit (`TypedText`).
- Nexo **autonome** (v1.45) : `ui/clicky/autonomy.dart` (`ClickyIdea`, `Autonomy.allowed` / `never` = jamais envoyer un
  message, supprimer, lancer une commande ; `prompt` Gemini JSON, `parse`, `rules` sans IA, `answer` « oui/non » à la voix).
  `ClickyController.startAutonomy` (Mon Hub, toutes les minutes) → `autonomyTick` (présent = `Win.idleSeconds` < 2 min,
  pas en plein écran, rythme `ClickyMind.ideaAllowed` : rarement/normal/souvent) → `decideIdea` → `proposeIdea` (boîte de
  Nexo avec Oui / Non / Plus tard `_IdeaButtons`, à l'oral ; envoyée à Nexo partout par `idea64`) → `answerIdea` →
  `_runIdea` (outil direct, ou `agent` = `_runAgent`). Il apprend (`recordDecision`, `likes/dislikes`, `skipTools` après 2
  refus). Retour après 20 min d'absence : `welcomeBack`. Outil `assistant_ajouter_plan_journee` (ajoute le plan, avec accord).
- Lecture dans la Bibliothèque (v1.46) : `modules/books/read_finder.dart` (`ReadFinder` : titre nettoyé `ReadQuery.parse`
  — « Tome 3 », « chapitre 12 », sous-titre —, recherche en parallèle MangaDex (scans, fr puis en, `contentRating` safe/
  suggestive seulement), Projet Gutenberg via gutendex (texte) et Internet Archive (accès **libre** seulement, pas
  d'emprunt) ; `confident` = ressemblance du titre ≥ 0,95 sinon « C'est celui-ci ? » ; `pickChapters` un chapitre par
  numéro ; chapitres officiels `externalUrl` ouverts dans le navigateur). `Book.read` = `ReadLink` (source, chapitre,
  page). Lecteurs : `modules/books/reader_page.dart` (`openReading`, `ScanReaderPage` page par page / webtoon / sens
  japonais, `TextReaderPage` liseuse avec texte gardé dans `lectures/`, `WebBookPage`). Outil Nexo `livre_ou_lire`.
  Jamais de site pirate ni de scraping : seulement ces API publiques.
- **Sécurité (v1.47)** : `SECURITY.md`. Pont local (`claude_bridge.dart`) : clé 64 hex comparée en temps constant
  (`sameKey`), refus des pages web (`fromThisPc` : Origin / Host), corps limité (`maxBody`), `/call` demande l'accord
  pour les actions d'écriture (sauf Nexo partout qui l'a déjà demandé : en-tête `x-monhub-client: clicky` +
  `confirme`). **Jamais `cmd /c start`** : `core/safe_open.dart` (`SafeOpen.launch` = ShellExecute, `risky` → accord
  via `PcControl.confirmRisky`). `PcControl.secretPath` (mots de passe, cookies, clés : jamais lus/écrits),
  `riskyWrite` (démarrage, scripts : toujours demandés), `dangerous` élargi. Bouclier anti-piège
  `core/prompt_shield.dart` (`wrap` = résultats d'outils extérieurs étiquetés « données », `tainted` 15 min → le mode
  auto redemande, `rule` dans les consignes Claude et Gemini Live). `ErrorLog.redact` (clés masquées). Mise à jour :
  empreinte SHA-256 obligatoire + `Updater.trustedUrl`. Workflow : `permissions: contents: read`, Dependabot.
- **Nexo économe** : `core/tool_router.dart` (`ToolRouter` : groupes d'outils par mots-clés, `pick`, méta-outils
  `mon_hub_outils` / `mon_hub_action` résolus par `resolve` pour garder les permissions, `cap` des résultats ;
  `/mcp?groupes=`), `ui/clicky/thrift.dart` (`ClaudeThrift.light` → Gemini, `heavy` → effort medium sinon low,
  `ClaudeUsage` compteur local), `cache_control` dans `ClaudeApi`, réglage `thrift`. Modèle conseillé : Claude Opus 5.5
  (`claude-opus-5-5`).
- **Ton fil** (modules reliés) : `core/hub_feed.dart` (`HubFeed.build` sans IA à partir des outils de lecture
  agenda/devoirs/révisions/livres + pastilles ; `say` pour Nexo), `ui/hub_feed_view.dart` (`HubFeedStrip` à
  l'accueil). Nexo proactif : `ClickyController.feedNudge` (1 info importante, ≤ 6/jour, 45 min d'écart) + retour.
- **Modules perso** : `core/custom_modules.dart` (`CustomModules` : catalogue, site https dans `HubWebView`, liste de
  liens ; `hub.custom` ; ids `perso_…`), `ui/add_module.dart` (carte « + » à l'accueil, `AddModuleSheet`),
  `HubController.add/remove`.
- **Lecture** : `modules/books/free_classics.dart` (`FreeClassics` : 1984 / La Ferme des animaux via Gutenberg
  Australie, libres en France ; `Wikisource` FR via l'API + ws-export). **Anime-sama refusé** (site pirate) : seulement
  sources légales (MANGA Plus, WEBTOON, MangaDex…).
- **Compte sur plusieurs appareils, sans export (v1.48–1.49)** : `core/account_sync.dart` (`AccountSync`). Copie du
  compte dans le Drive **de la personne**, dossier visible « Mon Hub - compte synchronisé » (`DriveFolder`, portée `drive`
  déjà donnée depuis la v1.37 → `GoogleAuth.canWriteDrive`, rien à reconnecter ; le rangement du Drive ne touche pas aux
  dossiers). Fichier `compte-<identifiant>.monhub` = `SyncBox` (gzip + AES-256-GCM, AAD = identifiant). Clé `SyncKey` =
  PBKDF2 de l'**empreinte** du mot de passe (`forAccount` : l'appareil connecté la connaît, aucune saisie ; nouvel appareil
  `fromPassword` avec `sel_compte` de l'en-tête ; copies v1.48 sans `sel_compte` = mot de passe brut), gardée dans le coffre
  `sync.key`. Contenu : préférences `p:`, secrets `s:`, fichiers `f:` (JSON de `HubFiles`), chacun `[valeur, date,
  empreinte]` ; fusion `SyncMerge` clé par clé, **le plus récent gagne**, suppressions gardées 90 j, garde-fou
  `checkNotWiped`. `sync-base.json` = empreintes de la dernière synchro. Jamais synchronisé : `sync.*`, `app.*`,
  `shortcut.*`, `hub.detached*`, `vault.key`, `rangement-*`. Toutes les 3 min (`start` dans `HubApp._sync`, `onApplied` →
  `HubController.reload`, Nexo). **PC principal hors de portée** : le nouvel appareil dépose `demande-compte-<id>.json`
  (`requestCopy`) ; Mon Hub ouvert sur le PC principal la voit (`answerRequests`, toutes les 5 min, tous les comptes Google
  connectés) → active la synchro tout seul, efface la demande, notification (`onNotice`). Nouvel appareil : page de
  connexion → « Retrouver mon compte d'un autre appareil » (`ui/account_sync_view.dart` `JoinAccountView` : `beginJoin`
  prépare l'espace où se range la connexion Google, bouton « Demander mon compte à mon PC principal » + attente toutes les
  20 s, `join` → `AppSession.adopt`, `cancelJoin` efface). **PC principal éteint** : compte recréé ici (même identifiant +
  mot de passe) → Réglages → « Récupérer les données de mon PC principal » (`askMainPc` : demande + `sync.ask`, `checkArrival`
  chaque minute, `arrived`) ; le PC principal répond avec `enable(takeOver: true)` (copie illisible pour lui → remplacée,
  `_sync(replace:)`) ; ici `mergeFrom(mot de passe)` = `_sync(remoteWins:)` (le PC principal gagne les doublons) ou
  `unlock` si la synchro était déjà active. Réglages → Mes appareils = `AccountSyncSection` ; l'export/import
  fichier reste dans « Sans internet ». Toujours **aucun serveur à nous**.
- Animations : `ui/clicky/alive.dart` (`ClickyBounce` : rebond à chaque état, halo en réflexion, saut de joie, coucou
  rare ; rien en boucle au repos), cartes de l'accueil soulevées au survol, 👋 qui salue une fois.
- **v1.50** — Pièces jointes **vues dans Mon Hub** : `ui/file_viewer.dart` (`FileViewer.open(context, nom, chargeur)` :
  PDF et audio/vidéo par WebView2 en `file://` (dossier temporaire `MonHub-apercus`, effacé après 1 j), photos,
  texte, Word → texte (`DocFormat` dans un Isolate), sinon « Ouvrir avec l'appli du PC » (`SafeOpen`, accord si
  `risky`) ; bouton « Résumer » = `FileViewer.summarize` (Gemini lit les PDF) ; `AttachmentChip`). Devoirs ED :
  `EdHomework.files` (`EdClient.homeworkFiles` : `aFaire.documents`, `ressourceDocuments`, `contenuDeSeance.documents`,
  type `FICHIER_CDT`) + `lesson` (fait en classe) ; outil `ecole_fichier_lire`. Messages / cloud / documents ED
  s'ouvrent dans la visionneuse. Mails : `MailModule.readMail` → `MailContent` + `attachmentsOf` (page de lecture
  Stateful : plus de reconnexion IMAP à chaque redessin).
- Google Docs plus fluide : `HubWebView` (progression en `ValueNotifier` = le navigateur n'est plus reconstruit à chaque
  %, réglages créés une fois, vérif « page blanche » légère en `textContent`, `reloadButton: false` pour ne plus cacher
  « Partager », `sameSiteInPlace` : un lien du même site s'ouvre ici, `_PopupWindow` avec titre + « ouvrir dans le
  navigateur »), identité Chrome = **vraie version du moteur** (`desktopUserAgent`, `WebViewEnvironment.getAvailableVersion`).
  Mode **fenêtre à part** : `Browser.openAppWindow` (Chrome/Edge `--app=`), `DocsModule.ownWindow` (bandeau « Toujours en
  fenêtre »).
- Gels : `core/freeze_watch.dart` (`FreezeWatch` : guetteur dans un Isolate, note « figé » dans `journal-erreurs.log`
  après 4 s sans battement, avec `FreezeWatch.note(...)` = ce que l'appli faisait ; démarré par `ErrorLog.install`,
  pas en debug). Photos de Révisions réduites hors du fil (`Photo.toJpeg`). Nexo coincé : `_armStuck` (écoute 2 min,
  réflexion 4 min sans nouvelle → `cancel()` + message, noté dans le journal).
- **Écouter un cours** : `ui/clicky/course_listener.dart` (`CourseListener` : micro `record` en WAV 16 kHz par morceaux de
  4 min, transcrits pendant le cours — Whisper d'abord (`Whisper.transcribe(timeout:)`), sinon `GeminiTranscriber` —,
  gardés au fur et à mesure dans `comptes-rendus.json` (`_put` par id), arrêt auto à la fin du cours (agenda) ou 4 h,
  compte rendu `AiText.ask(prompt)`), `ui/clicky/course_page.dart` (`CoursePage`, `CourseNotePage` → Google Doc
  `doc_creer` / cartes `revision_generer`, `CourseRecLayer` = pastille rouge dans le builder de `HubApp`). Outils
  `cours_ecouter` / `cours_arreter` / `cours_comptes_rendus` (groupe `cours` du `ToolRouter`), phrases sans IA dans
  `QuickAnswers` (« écoute le cours », « arrête le cours »). Bouton dans Révisions.
- Réglages de Nexo **rangés** : `ui/clicky/clicky_settings_page.dart` (`ClickySettingsPage` : recherche, « L'essentiel »,
  rubriques `ClickySection.all` → `ClickyMoreSettings(section:)` ou `(query:)`), `ClaudeModule.showSettings` = cette page,
  `ClaudeModule.showBrain` = le cerveau seul. Réglages de Mon Hub : une seule entrée « Réglages de Nexo ».
- **Nexo façon JARVIS (v1.51)** : `ui/clicky/jarvis.dart` — `SystemStatus` (FFI win32 : batterie `GetSystemPowerStatus`,
  mémoire, disque C:, processeur `GetSystemTimes` sur 0,4 s, internet ; `topMemory` = `tasklist /fo csv` regroupé ;
  `say()` « Tous les systèmes sont opérationnels » ou les soucis ; `batteryNow`/`batteryAlert` à 20 % puis 10 %),
  `FocusMode` (fichier partagé `concentration.json` : Nexo ne dit rien de lui-même — `_calm` et `autonomyTick` —,
  `NotificationCenter.post` garde les notifications (sauf appels Discord), bilan à la fin par `autonomyTick`, pastille
  `FocusPill` dans `CourseRecLayer`), `AppReminders` (`rappels-applis.json`, dit quand l'appli **arrive** au premier plan,
  `_checkAppReminder` dans `_presenceTick`), `ClickySituation` (bloc « En ce moment » dans `_system` et `_liveSystem`,
  préparé en avance, `_refreshSituation` 4 min). `thinkingRules` = façon de réfléchir. « Réfléchis bien » →
  `ClaudeThrift.deep` → effort `high`. Outils `pc_etat`, `pc_fenetres` (`windowCommand` : bureau, gauche/droite,
  agrandir, activer), `clicky_concentration`, `clicky_rappel_appli`, `clicky_situation` (`jarvisTools`), phrases sans IA
  dans `QuickAnswers` (« fais le point », « comment va mon PC », « pourquoi mon PC rame », « mode concentration 45 min »,
  « mets Chrome à gauche », « rappelle-moi de … quand j'ouvre … » ; durées `FocusDuration`).
  **Conversation continue** (réglage `followUp`, partagé) : après une réponse à une question posée à la voix
  (`_spokenAsk` → `_voiceTurn`, Live : `_liveStop`), `_followUpSoon` attend la fin de la voix et réécoute
  (`following`, `_armFollowTimer` : rien dit en 6 s → arrêt silencieux, 20 s max, 5 tours de suite). Page
  « Ce que Nexo sait faire » = `ClickySkillsPage` (`jarvis_view.dart`), en tête des réglages de Nexo.
- **Nexo partout colle à la souris (v1.52)** : c'est **Windows** qui déplace la fenêtre, dans le lanceur
  (`windows/runner/clicky_follow.cpp/.h` : raw input `RIDEV_INPUTSINK` → `SetWindowPos` à chaque mouvement, restant dans
  l'écran du curseur ; message `WM_APP + 0x51` envoyé par Dart = `Win.follow(on, dx, dy)`, décalage `Win.packOffset`).
  Dart (`_DesktopState._place`) ne reprend la main que pour les vols, la boîte ouverte, une fenêtre posée et les dessins
  (`_setNative(false)` relit `Win.windowRect`), vols calculés à chaque image (`Ticker _frames`) ; `Win.resize` (sans
  bouger) pour la taille et rester au premier plan. `moveCursor` ne redessine plus Nexo en mode partout. Captures :
  Nexo n'est plus caché (`Win.excludeFromCapture` = `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)`, sinon ancien
  repli), image réduite par Windows (`Win.captureScaled`, StretchBlt HALFTONE), **JPEG** fait dans un Isolate
  (`shot_encode.dart` `encodeShot` : alpha remis à 255 sinon blanc) ; `png64` peut donc être du JPEG → toujours annoncer
  `imageMime(b64)`. Le C++ se vérifie ici avec `x86_64-w64-mingw32-g++ -fsyntax-only -Wall -Wextra -Werror`.
- **Outils d'élève (v1.53)** : notes = `modules/ecoledirecte/grade_math.dart` (`GradeMath` : `EdGrade.coef/period/counts`
  lus d'École Directe, `currentPeriod` = période de la note la plus récente, `average` pondérée, `needed`/`sayNeeded`,
  `matchSubject` « maths » → MATHEMATIQUES, `weekReport`) ; outils `ecole_moyenne`, `ecole_bilan_notes`, notification
  « bilan » le vendredi ≥ 17 h (`poll`, id `bilan-notes:<lundi>`). **Prépare ton sac** : `ui/clicky/school_bag.dart`
  (`SchoolBag.plan/say`, une famille d'affaires par cours, réglages `parseCustom`), automatisme `sac` de l'`Assistant`
  (`bagMinutes` 19 h 30, `bagItems`, `_BagDialog`), outil `assistant_sac`. **Ctrl + Alt + C** (Nexo partout) =
  `ClickyController.fixSelection` (copie la sélection, `TextFix.prompt/clean/changes`, recolle, remet le presse-papier ;
  modes corriger / reformuler / traduire:langue ; outil `clicky_corriger_selection`). **Notifications regroupées** :
  `NotificationCenter.digest` (30 min par défaut, réglage), `urgent` (sans module, appels, cours annulés) passe,
  `digestOf`. **Sauvegarde des travaux** : `core/work_backup.dart` (`WorkBackup` : Documents/Bureau → Drive « Mon Hub -
  Sauvegardes », fichiers `wanted` modifiés seulement (`changed`), jamais de suppression, `sauvegarde.json` jamais
  synchronisé), `ui/backup_page.dart`. **Contrôle blanc** : `modules/revisions/mock_exam.dart` (`MockExam.prompt/parse`
  — JSON objet lu par `_object`, pas `AiText.json` qui préfère les tableaux —, `mark` QCM auto + rédigé corrigé par l'IA,
  `on20`, `MockExamPage` chronométrée), bouton dans `DeckPage`, outil `revision_controle_blanc`. **Notes en direct** :
  `CourseListener.start(liveDoc:)` crée un Google Doc ouvert en fenêtre, `_writeLive` y ajoute chaque morceau mis au
  propre (`livePrompt`), compte rendu à la fin ; `CourseNote.docId`.
- **Extension Chrome + « fais-le à ma place » (v1.54)** : `assets/chrome-extension/` (MV3 : `manifest.json` avec
  `key` → id fixe `nejfhocplopdmnijfodbmcbelcciblji`, `background.js` : WebSocket `ws://127.0.0.1:47614/navigateur`,
  réveil `chrome.alarms`, commandes tabs/open/read/describe/click/type/key/focus/close, pages bloquées `BLOCKED`, onglets
  dans le groupe « Nexo », vrai clavier/souris par `chrome.debugger` (CDP `Input.insertText`) ; **les fonctions
  injectées dans la page ne voient pas le reste du fichier** — `find` y est celui du navigateur). Testé en vrai avec
  Playwright (Chromium, `channel: 'chromium'`, `--load-extension`). Côté Mon Hub : `core/browser_link.dart`
  (`BrowserLink` : serveur local, `allowedOrigin`, `call`, outils `nav_*`, `risky` → `confirm`, `trustedUntil`,
  `step`, `guide`), démarré dans `HubApp._sync`. Installation : `ui/clicky/browser_setup_page.dart` (copie les
  ressources dans %APPDATA%\MonHub\extension-chrome, ouvre chrome://extensions). Tâches de fond :
  `ui/clicky/background_tasks.dart` (`BackgroundTasks.start` → `runner` = `ClickyController.runTask`, pastille
  `TaskPill`, `cancel`), `ClickyController.forMeRe` (« fais-le à ma place », « en arrière-plan », « agent, »)
  → `doForMe` (Nexo partout passe par l'outil `clicky_a_ma_place` de Mon Hub), `confirmBrowser`. Sécurité :
  `nav_cliquer/ecrire/touche/fermer` = actions à autoriser (`isWriteAction`), sauf pendant une tâche (`trusted`),
  `nav_lire/onglets` = données extérieures (`PromptShield`). Voir `SECURITY.md`.
- **Devoirs (v1.55)** : Nexo **fait** les devoirs quand on le lui demande (demande de la personne) — plus de « tu
  guides sans faire à sa place » : `clickyPersona(helpOnly:)`, `ClickyController.homeworkRules` (énoncé trouvé à l'écran,
  `ecole_devoirs`, `ecole_fichier_lire mode=enonce` = `FileViewer.summarize(full: true)`, travail complet + « Comment j'ai
  fait », long → Google Doc). « Fais mes devoirs (de maths pour lundi) » = `homeworkRequest` → `homeworkTask` → tâche
  de fond `doForMe`. Réglage `helpOnly` (« Aider sans faire à ma place », désactivé par défaut, partagé) remet l'ancien
  comportement.
- **v1.56 — vie hors école** : bouclier anti-arnaque `core/scam_shield.dart` (`ScamShield.checkUrl/checkMessage`, sans IA,
  sosies seulement de `_phished`, marques en mots entiers ; Discord `poll` + mails `MailModule.scamOf` → notifications
  `arnaque:` qui passent toujours ; `Browser.confirmScam`, `HubWebView.onCreateWindow`) ; bilan de sécurité
  `core/security_check.dart` + `ui/security_page.dart` (PowerShell SecurityCenter2/Defender/pare-feu/HotFix/UAC, 2FA Discord
  `discord_securite`, autres comptes à cocher `secu.fait`) ; « qu'est-ce que j'ai raté ? » `ui/clicky/catch_up.dart`
  (`CatchUp.build/short/gather`, `discord_mentions`, pubs filtrées, dit au retour par `autonomyTick`) ; temps d'écran
  `core/screen_time.dart` (`ScreenTime` tour 15 s dans `HubApp._sync`, `temps-ecran.json` **jamais synchronisé**,
  `appName` sites d'après le titre, `matchApp`, limites douces, `Sleep.bedtime`, automatisme `sommeil` +
  `assistant_coucher`), `GameMode` (plein écran ≥ 30 s hors `notGame` : notifications gardées, sauvegarde et synchro en
  pause, Nexo partout caché, bilan à la fin ; `jeu.auto`), page `ui/screen_time_page.dart` (Réglages → Bien-être) ;
  recherche partout `core/everywhere_search.dart` (`EverywhereSearch.run` : outils de lecture + index Windows ADODB
  `pcScript`, `pcQuery` nettoie les mots ; `fromTool` par outil) + `ui/search_page.dart` (`SearchPage.show`, Ctrl + Espace
  via `HubHome.onSearchText`, Ctrl + Alt + Espace dans Nexo partout → `recherche_ouvrir` + `Win.raiseMain`, bouton 🔍 de
  l'accueil) ; anniversaires `core/birthdays.dart` (`anniversaires.json` synchronisé, `nameInTitle` agenda, `parseDate`,
  `upcoming`, `wish`) + automatisme `anniversaires` (veille 19 h, jour même 8 h) + `ui/birthdays_page.dart`. Outils dans
  `ClickyController.lifeTools` / `jarvisTools` / `Assistant.tools`, groupes `securite`/`recherche`/`ecran`/`anniversaires`
  du `ToolRouter`, phrases sans IA dans `QuickAnswers` (`original` retrouve les accents d'un prénom).
- **iPhone (v1.56)** : job `ios` du workflow réactivé (non signé, `MonHub-iOS.ipa` ajouté à la version par `release-ios`
  sans retarder Windows ; `release` seulement sur main). Installation Sideloadly (INSTALL.md, `ui/phone_setup_page.dart`
  = Réglages → Mes appareils → Ajouter mon iPhone, Windows seulement). Connexion Google sur iPhone : même client « bureau »,
  page Google dans Safari intégré (`LaunchMode.inAppBrowserView`, `closeInAppWebView`) + adresse de bouclage. Clé Google
  du PC → iPhone par **code de liaison** (`GoogleAuth.shareCode/importCode`, `MONHUB-GOOGLE:` base64 ; `PasteGoogleCode`
  dans `JoinAccountView` et `GoogleSetupPage`), puis « Retrouver mon compte » = `AccountSync` (synchro existante). Pas de
  mise à jour auto sur iPhone : `Updater.phoneUpdate` → notification. Rien de Windows au démarrage sur iOS (`BrowserLink`
  bureau seulement).
- **Mon téléphone** (pont téléphone ↔ PC par le Wi-Fi, sans cloud) : `core/phone_link.dart` (`PhoneLink` : serveur sur
  0.0.0.0 port fixe **47615** (sinon au hasard), seulement les appareils du réseau local (`localClient`), **lien secret**
  `/t/<32 hex>/` (`app.phone.token`, prefs `app.*` jamais synchronisées, `newLink` délie, `sameKey`), activé par
  `app.phone.on`, démarré dans `HubApp._sync` (ordinateur seulement), arrêté au changement de compte. API : `api/etat`
  (presse-papier du PC, fichiers proposés), `api/envoyer` (fichier en flux, en-tête `x-nom`, `safeName`, jamais
  d'écrasement `uniqueFile`, ≤ 4 Go → Téléchargements\Depuis mon téléphone, notification groupée), `api/texte` →
  presse-papier du PC, `api/fichier/<id>` (fichiers proposés par `share`), `api/commande` → `PhoneRemote.run`
  (`ui/phone_link_page.dart` : touches médias, flèches/F5/F11, `Win.mouseBy/clickHere/scroll`, `Win.lock`, `Win.sleep`
  (powrprof SetSuspendState), `shutdown /s /t 60` + `/a`). `extraRoutes` = autres pages sur le même serveur (soirée).
  Page du téléphone : `assets/phone/` (onglets Envoyer / Du PC / Texte / Télécommande, pavé tactile 1 doigt = souris,
  2 doigts = défiler, toucher = clic ; « Sur l'écran d'accueil » iPhone). Mon Hub : `PhoneLinkPage` (QR `QrView`, paquet
  `qr`), bouton de l'accueil + Réglages → Mes appareils → Mon téléphone. Outil Nexo `telephone_envoyer` (groupe
  `telephone`). Le pare-feu de Windows demande l'autorisation la 1ʳᵉ fois.
- **Playlist de soirée** : `core/party.dart` (`Party` : route `extraRoutes` du serveur de `PhoneLink` (démarré avec
  `start(force: true)`, arrêté à la fin si « Mon téléphone » n'est pas activé), lien des invités `/soiree/<24 hex>/` qui
  ne donne **que** la soirée (jamais fichiers/télécommande), `api/chercher` (recherche YouTube faite par le PC, 1 / 0,8 s
  par invité), `api/ajouter` (id vidéo vérifié, textes nettoyés `clean`, 5 sons en attente par invité, doublon = vote),
  `api/voter` (bascule), file `upcoming` triée par votes puis arrivée). Page invités `assets/party/` (prénom gardé dans le
  téléphone). PC : `ui/party_page.dart` (`PartyPage.open` : lecteur = vraie page YouTube dans `HubWebView` + CSS
  `YouTubeMiniPlayer.script`, sondage 1 s de `movie_player.getPlayerState()` : 0 = fini → `next()`, pub ignorée, bloqué
  20 s → suivant ; QR des invités, ajout par l'hôte, retirer, pause, suivant ; quitter = terminer). Outil `soiree_ouvrir`
  (groupe `soiree`), « lance une soirée » / « mode soirée » sans IA, bouton dans la page Mon téléphone.
- **Mon argent** (module `argent`, `modules/money/`, carte de l'accueil) : **sans IA**. `money_rules.dart` (`MoneyRules` :
  `knownServices` (Spotify, Netflix, Deezer, Disney+, Prime, YouTube Premium, Apple/Google avec un mot-clé obligatoire,
  Game Pass, PS Plus, Nitro, Roblox Premium, Crunchyroll, ChatGPT…), `subscription` = essai / renouvellement / paiement /
  résiliation + prix `amount` + date `date`/`dateAfter` (FR et EN, sans année = prochaine fois), paiement sans date =
  +1 mois / +1 an ; `parcel` = transporteur + numéro (Colissimo, Chronopost, UPS, DHL, Mondial Relay, Relais Colis, GLS,
  DPD, Amazon ; numéros courts seulement si le mail vient du transporteur) + état `status` (commande → expédié → livré
  aujourd'hui → à retirer → livré, `later` : jamais de recul) + lien de suivi `trackingUrl`). `money_store.dart`
  (`MoneyStore`, `argent.json` chiffré : abonnements, colis, jeux, mails déjà lus `vus`). `MoneyModule(mail:)` (le
  `MailModule` est partagé dans `module_registry`) : `scanMails` (toutes les 30 min, 80 derniers mails, ≤ 15 lus en entier),
  `refreshGames` (Epic 6 h, Steam 12 h), `reminders` (veille / jour du prélèvement ou de la fin d'essai dès 9 h, colis
  à retirer / livré, jeu gratuit, promo Steam ; doublons filtrés par le centre de notifications). `games_deals.dart`
  (`GameDeals.epic` = freeGamesPromotions public, `steamId` (lien, pseudo via `?xml=1`, numéro), `steamDeals` =
  IWishlistService/GetWishlist + appdetails `price_overview` par 50 (Steam renvoie `data: []` sans prix), remise ≥ 20 %).
  Outils `argent_abonnements/colis/jeux` (groupe `argent`), phrases sans IA (« mes abonnements », « où est mon colis »,
  « jeux gratuits »). **Mots de passe fuités** : `core/pwned.dart` (`PwnedPasswords` : k-anonymat, SHA-1 sur l'appareil,
  seuls 5 caractères envoyés, `Add-Padding`), carte `PwnedCheckCard` dans le bilan de sécurité (mot de passe effacé
  après la vérification, jamais gardé).
- **Outils d'études (vague 3)**, menu ✨ de Révisions + outils Nexo (groupe `etudes`) :
  **Correction de copie** `ui/clicky/copy_check.dart` (`CopyCheck` : photo → `Photo.toJpeg` 1800 px → `AiText.ask` (Gemini
  d'abord) avec `box_2d` [ymin, xmin, ymax, xmax] en millièmes, `parse` remet dans l'ordre et borne ; `CopyCheckPage` :
  cadres colorés numérotés par type sur la photo (`InteractiveViewer`), liste faux → correction + règle, note /20 ; une
  photo reçue par « Mon téléphone » s'ouvre toute seule), outil `copie_corriger`, « corrige ma copie ».
  **Coach d'oral** `ui/clicky/oral_coach.dart` (`OralCoach` : enregistrement `record` WAV 16 kHz, blancs > 3 s comptés
  sur l'amplitude, Gemini **écoute l'audio** (`listen`, < 19 Mo) sinon `CourseListener.toText` + `AiText` ; `fillers`
  (euh, du coup, en fait, genre, « quoi » en fin de phrase…), `wpm` + `paceAdvice` (120–160), note, plan oublié,
  questions du jury lues par `ClickyController.speak(force: true)`, réponse à l'oral jugée `judgeAnswer`), outil
  `oral_coach`, « entraîne-moi pour mon grand oral ». **Vidéo → fiche** `ui/clicky/video_notes.dart` (`VideoNotes` :
  Gemini regarde la vidéo publique (`file_data.file_uri` YouTube), sinon sous-titres `captionTracks` + `fmt=json3` avec
  les minutes + `AiText` ; chapitres cliquables → `YouTubeModule.open` à la seconde, quiz, Google Doc / cartes), outil
  `video_fiche`. **Carte mentale** `ui/clicky/mind_map.dart` (`MindMaps.parse` 3 niveaux, `layout` radial (240 px puis
  +200 par niveau, chaque branche dans sa part du cercle), `MindMapPage` : une seule `AnimationController` interpole
  positions des idées et des liens (`_Links`), déplier/replier, « Nexo explique » à voix haute, Google Doc / cartes),
  outil `carte_mentale`, « fais une carte mentale sur … ».
- **Langues** (groupe `langues`) : **Interprète** `ui/clicky/interpreter.dart` (`GeminiLive(autoVad: true, language: null,
  tools: [])` : Gemini repère seul les tours de parole, consignes `Interpreter.system` = traduire seulement ; micro coupé
  pendant que la traduction est lue (`PcmPlayer.playing`) pour ne pas se traduire lui-même ; transcriptions entrée /
  sortie affichées), outil `interprete_ouvrir`, « interprète anglais ». `GeminiLive` : `tools` et `realtimeInputConfig`
  omis quand vides / `autoVad`, `languageCode` omis si `language` null (Nexo inchangé). **Sous-titres en direct**
  `ui/clicky/loopback.dart` (`LoopbackCapture` : WASAPI en boucle (`AUDCLNT_STREAMFLAGS_LOOPBACK`) dans un Isolate, format
  de mixage float32 ou int16 → mono → `Resampler` (interpolation linéaire, sans couture) → PCM 16 kHz) +
  `ui/clicky/live_captions.dart` (`hub.exe --widget=soustitres` → `runCaptionsWindow` : fenêtre à part, toujours au
  premier plan en bas de l'écran ; morceaux de 8 s (14 s après un 429), silence ignoré, `OralCoach.listen` envoie le WAV
  à Gemini qui écrit la traduction (`LiveCaptions.prompt/clean`, « (rien) » = pas de paroles), sinon Whisper `lang: auto`
  (langue d'origine) ; quitter = `DesktopWidgets.send(id, 'quit')`), outil `soustitres_lancer`, « mets les sous-titres ».
  Les deux sont aussi dans le menu ✨ de Révisions.
- **Nexo vivant (v1.57)** : il **garde son look de curseur** (pas de visage, demande de la personne) et vit avec des
  **émojis** à côté de lui. `ui/clicky/life.dart` (`ClickyLife` : `show` émoji passager, `shown` (💤 quand il dort, 🎵
  quand il danse), accessoire `refreshAccessory` — fêtes `seasonAccessory` (🎅 1–26 déc., 🎃, 🥳, 🐟…) > vraie météo
  `weatherAccessory` (résultat de `carnet_meteo` : 🧣 ≤ 4 °C, ☂️, ⛄, 😎 ≥ 28 °C) ; ☕ le matin passe avant tout —,
  `energyAt/sleepyAt`, sommeil `fallAsleep/wake`, rêves `dreamFrom` (sans IA) / `dreamPrompt` (Gemini) / `cleanDream`,
  1 par jour, `feelingFor` (notifications : note ≥ 15/20 🤩 + phrase, < 10 🫂 + phrase, cours annulé 🥳, arnaque 🚨…),
  `answer` sans IA (« tu dors ? », « t'as rêvé de quoi ? », « pourquoi t'as une écharpe ? », « sois plus discret »,
  « arrête de danser »), `promptBlock` dans les consignes Claude et Gemini Live, détecteurs `WiggleDetector.shake/pet`,
  `RageClickDetector`, `BeatDetector` (PCM 16 kHz, `steady` = vrai rythme, pas une voix), `gameLike`). **Garde-fous
  anti-saoulant** : `mayTalk` (bulles muettes : 2/h, 8/j, 10 min d'écart ; « discret » 1/h, 4/j, 30 min), `mayEmoji`
  (même émoji pas en boucle), `once` ; jamais sa voix de lui-même ; rien en plein écran, jeu, concentration.
  Affichage : `ui/clicky/life_view.dart` (`ClickyLifeBody` autour de `_Pointer` : émoji qui « pop », 💤 qui flotte,
  accessoire, saut sur chaque battement, tangue au tournis ; `LifeMotion` ; `emojiFonts`). Contrôleur (`ClickyController`,
  section « Sa vie à lui ») : `_lifeTick` dans `_presenceTick` (endormi après 4 min sans souris ni clavier → vole vers
  `restSpot` ; réveil = souris ≥ 160 px, clavier ou clic → 😮 🥱 ; bâille le soir ; s'ennuie → émoji après 1 h 30 sans
  question ; café + rêve le matin), `_perch` (1 regard sur 4 : assis en haut de la fenêtre `perchSpot`, tombe 😱 si elle
  bouge / change, caresse = petits allers-retours 🥰 `ClickyMind.petted`, souris qui approche = il revient),
  `_lifeMove` (dans `moveCursor` ; `_lifeHold` empêche le retour auto), `userClicked` (clics, Nexo partout `_loop`),
  `_checkDance` (Nexo partout : `musique_joue` du module Musique, sans rien recharger, puis `LoopbackCapture` →
  `BeatDetector`), `reactTo` (branché sur `NotificationCenter.onAny` dans `HubApp._sync`) → `feel` (`feel64` vers
  Nexo partout), `lifeNote` (sa bulle, qui suit la souris). Réglages dans `ClickyMind` (`life`, `life.dance`,
  `life.perch`, `life.react`, `lifePace`, `lifeState` = dernier rêve / sieste) et Réglages → Conscience de Nexo
  (« Sa vie à lui »). Tests : `test/v169_alive_test.dart`.
- **Yeux et oreilles de Nexo (v1.58)** : il voit l'écran et entend le son du PC **en continu, sur le PC** (demande de la
  personne). `core/screen_memory.dart` (`ScreenMemory` : `memoire-ecran.json` chiffré, 7 jours, 1 500 moments, **jamais
  synchronisé** (`AccountSync.syncedFile`), `ScreenMoment` vu/entendu (`heard`), même fenêtre + même texte = prolongé,
  `search` (mots, pluriels), `between`, `say/sayBetween`, `forget` ; `TimeWindow.parse` : hier (soir), mardi vers 16 h,
  il y a 20 min, tout à l'heure…). `ui/clicky/senses.dart` : `SenseRules` (sans Windows, testables : `privateWindow` =
  messageries, mails, banque, mots de passe, navigation privée, ED/Pronote, Mon Hub → **jamais regardés** ; `callLikely`
  (sessions audio d'un programme d'appel, ou navigateur qui joue + onglet Meet/Discord/Zoom…) → **jamais écouté pendant un
  appel** (enregistrer les paroles d'autrui sans accord est interdit) ; `thumb/changed` (aperçu 64 × 36 : relire seulement
  si la fenêtre change, 1 lecture / min max par fenêtre), `cleanOcr`, `errorShown`, `deadline`, `english`, `importantLine`
  (« retenez bien », « ça tombera au contrôle »), `distraction` + `procrastinationLine`), `AudioSessions.active` (COM
  `IAudioSessionManager2` dans un Isolate), `ClickySenses` (dans Mon Hub, `tick` appelé par le tour de 15 s du temps
  d'écran dans `HubApp._sync` : OCR Windows de la fenêtre (`ClickyOcr.read(name: 'clicky-sens.jpg')`), son = `LoopbackCapture`
  → morceaux de 20 s → silence/musique ignorés → `Whisper.transcribe(lang: 'auto')` local (Whisper obligatoire, pas de
  Gemini en continu : quota) ; initiatives via `propose` = `proposeIdea` (6/jour, 15 min d'écart) : erreur à l'écran →
  `clicky_expliquer_ecran`, date limite → `agenda_ajouter`, vidéo en anglais → `soustitres_lancer`, « à retenir » →
  `think` muet + `notes`, procrastination le soir (devoir/contrôle demain + 40 min de distraction) → `clicky_concentration`
  25 min ; `sens-recent.json` (petit, 1/min) → `ClickySenses.promptBlock` (`_sensesBlock` du contrôleur, dans `_system` et
  `_liveSystem`, étiqueté `PromptShield.wrap`). Réglages propres au PC : `app.sens.ecran` / `app.sens.son` (éteints par
  défaut, consentement), `app.sens.recadrer` ; annonce une fois (`_announceSenses`). Outils `memoire_ecran`,
  `memoire_oublier`, `sens_etat`, `sens_regler` (**action à autoriser**, `isWriteAction`), `clicky_expliquer_ecran`
  (groupe `memoire` du `ToolRouter`), phrases sans IA dans `QuickAnswers` (« tu te souviens du site sur… », « qu'est-ce
  que je faisais mardi vers 16 h », « qu'est-ce qu'il a dit ? », « oublie les 10 dernières minutes », « ferme les yeux
  pendant 1 h », « regarde mon écran »). Page `ui/clicky/senses_page.dart` (Réglages de Nexo → Ses yeux et ses
  oreilles). Tests : `test/v170_senses_test.dart`.
- **Presse-papier malin + PC qui réagit (v1.58)** : `ui/clicky/pc_watch.dart`. `ClipSmart.classify` (sans IA) : lien
  d'arnaque (`ScamShield.checkUrl`, même copié dans une messagerie) → bulle + notification ; calcul (`Calc`, pas les dates /
  numéros) → résultat ; colis (`parcel` : UPS, Colissimo, Chronopost, Amazon) / adresse (`address`) → `pc_ouvrir` (suivi,
  Google Maps) ; date (`DateSpotter`) → `agenda_ajouter` ; anglais (`SenseRules.english`) → `clicky_presse_papier`
  traduire (recopié) ; long texte → résumer ; `looksSecret` = jamais les mots de passe / clés, ni depuis `isSensitiveTitle`.
  `PcWatch` (Mon Hub, Windows) : `GetClipboardSequenceNumber` toutes les 1,5 s, marqueur `clip-ignore` écrit par
  `fixSelection` (`PcWatch.markClipboardUse`) + `ignoreClipboard` ; dossiers Téléchargements et Images\Screenshots surveillés
  (`Directory.watch`, fichier stable 3 s, `PcRules.partial`) → cours → `pc_ranger_fichier` (un seul fichier vers
  Cours/<matière>, journal `rangement-*`, **action à autoriser**) ; capture → `pc_lire_image` (OCR → presse-papier) ; `tick`
  (15 s) : clé USB (`GetLogicalDrives`, `DRIVE_REMOVABLE`, `PcRules.suspicious` → alerte), appli « (Ne répond pas) » 30 s
  → `pc_etat`, disque < 5 Go → `pc_ranger_apercu`. Idées dans le budget commun `ClickySenses.offer`. Réglages
  `app.clip.malin` / `app.pc.reagit` (oui par défaut) dans la page Ses yeux et ses oreilles. Tests `test/v171_pc_watch_test.dart`.
- **Ville** (météo, accessoires de Nexo) : Carnet → Réglages, ou Réglages de Nexo → Conscience → Sa vie à lui, ou
  « j'habite à Lyon » (`ClickyLife.cityFrom` dans `_handleSelf` → `Carnet.setSetting('city')`).
- **« Préviens-moi quand… » (v1.58)** : `ui/clicky/watchers.dart`. `WatchParse` (sans IA : `lead` = « préviens-moi / dis-moi /
  tu me dis quand… », `parse` → `Watch` note (matière), devoir, message (Discord / ED, `mail` = mails seulement), page (lien
  dans la phrase ou copié, https, jamais Instagram / Discord / ED / banque), prix (jeu Steam : `appdetails`), internet,
  téléchargement ; sinon une explication — « Je ne sais pas encore… » = la phrase part vers l'IA), `matches` (via
  `NotificationCenter.onAny`, aucune requête en plus), `visibleText` (sans scripts ni compteurs). `Watchers` (`guetteurs.json`,
  **jamais synchronisé**) : `add/remove/say`, `onNotification`, `onDownload` (appelé par `PcWatch`), `tick` 1 min (internet
  `online`) / 30 min (pages, prix) ; un guetteur se déclenche **une fois** → notification + `think`. Outils `guetteur_creer`,
  `guetteur_liste` (groupe `guetteurs`). **Réponses toutes prêtes** (`Replies`, réglage `app.reponses`) : message privé
  Discord avec une question (sans lien) → idée → `clicky_brouillon_reponse` (une réponse courte, **copiée**, jamais envoyée).
- **Habitudes (v1.58)** : `ScreenTime.hours` (jour → heure → appli → secondes, 35 j). `ui/clicky/habits.dart` (`Habits.find`
  : ≥ 10 min, 3 semaines sur les 4 dernières ; `upcoming` ; `nudge` = « d'habitude à 14 h c'est Roblox… contrôle de SVT
  demain : 20 min avant ? » (`ClickySenses._habitNudge`, une fois par jour) ; `insights` : habitudes, heure la plus active,
  heure où tu quittes le PC, appli n° 1). Outil `clicky_habitudes`, « mes habitudes », section « Ce que Nexo a remarqué »
  dans la page Temps d'écran.
- **Veille sur tes artistes (v1.58)** : `ui/clicky/interests.dart` (`ArtistWatch` : 2 fois par jour, `topArtists` des titres
  likés (`musique_titres_likes`), API publique Deezer (recherche d'artiste + albums), `fresh` < 10 jours, 3 annonces max,
  `veille.json` jamais synchronisé, réglage `app.veille`). Interrupteurs dans la page Ses yeux et ses oreilles. Tests :
  `test/v172_watchers_test.dart`.
- **Menus plus clairs + nouvelle visite (v1.59)** : Réglages de Mon Hub (`ui/settings_page.dart`) = recherche + carte
  **Nexo** en tête (`_ClickyHero` : Réglages de Nexo, Ce qu'il sait faire, Revoir la visite) + rubriques
  `SettingsCategory.all` (Mon compte, Apparence, Notifications, Mes modules, Mes appareils, Google/sauvegarde/rangement,
  Bien-être, Sécurité et vie privée, Démarrage et raccourcis ; `find` par mots-clés, `clickyMatches`) ouvertes chacune sur
  sa page (`_SettingsSection`, contenu `_content(id, context, refresh)` — utiliser `refresh()` et pas `setState` dedans).
  Réglages de Nexo (`clicky_settings_page.dart` `_groups`) rangés par thème : Bien démarrer, Lui parler, Ce qu'il fait
  pour toi, Sa personnalité, Vie privée et avancé. Catalogue **« Ce que Nexo sait faire »** = `ui/clicky/skills.dart`
  (`ClickySkills.groups` : `SkillGroup` emoji/titre/`isNew`, `Skill(text, tryIt:)` ; recherche `search`, filtres, ▶ =
  essayer → `ClickyController.askAnywhere` ; bouton ✨ dans l'en-tête de l'accueil) — **y ajouter chaque nouvelle
  capacité**. Visite guidée `ui/clicky/tutorial.dart` (`ClickyTutorial.tour` : 11 `TourPage` avec `examples` à essayer
  en direct et `badge` « Nouveau » ; animations `_TaskVisual`, `_SensesVisual`, `_IdeaVisual`, `_WatchVisual`,
  `_LifeGridVisual`, `_AliveVisual` (vrai `ClickyLifeBody`) ; `FittedBox` sur petit écran ; clé `tutorial.v159` =
  remontrée une fois à tous ; changer la clé quand la visite change beaucoup). Tests `test/v173_menus_tour_test.dart`.
- **v1.60 — Mon Hub en ligne + interface HUD** (demande de la personne : « un vrai truc », espaces partagés entre
  comptes, même compte partout, Android + iPhone, toutes les applis, chat entre comptes et entre Nexo).
  **Serveur** = projet Supabase de la personne : `supabase/schema.sql` (tables `profiles`, `spaces`, `space_members`,
  `tasks`, `messages`, `account_files` ; RLS partout ; ajout de membres seulement par RPC `create_space` / `join_space`
  (code 10 hex) / `open_dm` (@pseudo) / `new_invite_code` ; temps réel messages/tâches/membres), copié dans l'appli
  (asset) et guide `docs/SUPABASE.md`. Client Dart pur (paquet `supabase`, pas `supabase_flutter`) :
  `core/online/online.dart` (`Online` : serveur = `--dart-define SUPABASE_URL/SUPABASE_ANON_KEY` (secrets GitHub, vides
  par défaut) sinon `app.online.server` réglé dans l'appli ou code `MONHUB-SERVEUR:` (`OnlineServer.code/fromCode`) ;
  session gardée par compte dans le secret `sync.online.session` (jamais synchronisé) ; le serveur reçoit
  `authPassword` = sha256, jamais le mot de passe ; `explain` = erreurs en français ; profil nom + `@pseudo`).
  **Même compte partout** : `AccountSync.defaultCloud` → `OnlineCloud` (`core/online/online_cloud.dart`, table
  `account_files`) quand le « mail » est `monhub:<adresse>` (`Online.syncMail`) : même `SyncBox` chiffrée, même fusion.
  `core/online/online_account.dart` (`putOnline` = même mot de passe que Mon Hub, `join` = nouvel appareil : page de
  connexion → « Mon compte en ligne » (`ui/online/online_sign_in.dart`), `NoOnlineCopy` → créer le compte ici).
  Réglages → « Compte en ligne et espaces » → `ui/online/online_page.dart` (serveur en 4 étapes, « Copier le script »,
  compte, profil, Nexo entre eux). **Espaces** : `core/online/spaces.dart` (`Spaces` : liste, membres, profils,
  non lus, épinglés `hub.spaces.pinned` (synchronisés), tâches `todo/doing/review/done`, messages, un seul canal temps
  réel + relecture toutes les 2 min, `onMessage` → notification `espace:<id>:<n>` + Nexo). UI : `ui/spaces/` (`SpacePage`
  tableau glisser-déposer + discussion, `SpacesPage`, `SpaceActions` créer/rejoindre/message/inviter). **Nexo dans les
  discussions** : `core/online/clicky_chat.dart` (`@clicky` dans **mon** message → **mon** Nexo répond ; entre Nexo
  seulement si `spaces.clicky_chat` ET réglage `hub.clickychat.autres` ; un seul répond (`replyTo`), `maxDepth` 4, 15 s
  d'écart, 30/jour ; aucun outil ; messages étiquetés `PromptShield.wrap('espaces_messages')`). Branché dans
  `HubApp._startOnline`. **Interface** : `ui/app_shell.dart` (menu : Aujourd'hui, Mes applis, Espaces (épinglés
  d'abord), Discussions, Modules — sections repliables `hub.menu.replie` ; téléphone : barre Aujourd'hui / Espaces /
  Chercher / Menu en tiroir), `ui/home_page.dart` (en-tête HUD, console Nexo : question → `ClickyController.ask`, ou
  nom d'appli → Entrée l'ouvre ; blocs) + `ui/hud/home_layout.dart` (`HomeLayout` : blocs `mod:<id>` / `fil` /
  `espaces` / `taches` / `discussions` / `applis`, largeur S/M/L, `resolve`, `rows` (rangées construites **à la
  demande** : SliverList), mode « Personnaliser » glisser/taille/retirer/ajouter, `hub.accueil.blocs`). **Toutes les
  applis du PC** : `core/pc_apps.dart` (`PcApps` : `Get-StartApps` → `parse` (sans désinstalleurs/liens), lancement
  `shell:AppsFolder\<AppID>` par `SafeOpen.launch`, épinglées/usage `app.applis.*` propres au PC, `match`), page
  `ui/apps_page.dart` (`AppTile`), dans la recherche (Ctrl + K ou Ctrl + Espace ; Ctrl + Alt + Espace partout) et la
  console. **Android** : job `android` réactivé (non bloquant) + `release-android` ajoute `MonHub-Android.apk` ;
  `Updater.phoneUpdate` prévient sur Android comme sur iPhone. Tests : `test/v174_online_test.dart`, `test/v135_test.dart`
  (nouvel accueil).
- **Mode léger (v1.61)** : `core/perf.dart` (`Perf` : réglage `app.perf` = auto / `leger` / `complet`, détection
  `PerfRules.modest` (cœurs `Platform.numberOfProcessors` + mémoire `GlobalMemoryStatusEx`), `Perf.slow(durée)` pour
  tous les tours de surveillance, `Perf.everywhere` (Nexo partout = second programme, **coupé** sur un PC modeste :
  c'est ce qui l'empêchait de démarrer), `Perf.heavy` (yeux/oreilles, sauvegarde, guetteur de gels), `Perf.animations`,
  `Perf.later(rang, …)` = **démarrage étalé** au lieu de tout lancer à la connexion dans `HubApp._sync`). Branché dans
  `main.dart`, `screen_time.dart`, `pc_watch.dart`, `senses.dart` (`screenOn`/`soundOn` faux en mode léger),
  `clicky.dart` (`_startPresence`), `clicky_desktop.dart` (`launch`/`watch`/boucle 16 ms), `error_log.dart`
  (`FreezeWatch`). Réglages → Vitesse de l'appli. Tests `test/v175_perf_test.dart`.
- **Interface simplifiée (v1.61)** : accueil (`ui/home_page.dart`) = **un seul** menu « Plus » en haut (notifications +
  `PopupMenuButton` : ce que Nexo sait faire, mon téléphone, clair/sombre, personnaliser, réglages) au lieu de sept
  boutons dont trois doublaient le menu de gauche ; plus de faux jargon (« SYSTÈME OK », « RIEN DE NOUVEAU », code-barres) :
  des phrases normales. Menu (`ui/app_shell.dart`) : **une seule** section « Espaces et messages » (avant « Espaces » +
  « Discussions », mêmes pages) avec un seul « + » (créer / rejoindre / écrire). Tests `test/v162_iphone_test.dart`
  (bouton « Plus »).
- **Caméra et micro protégés (v1.61)** : `core/camera_guard.dart` (`CameraRules` sans Windows : `appName` (chemin ou
  paquet), `expected`/`unexpected`, `fromFileTime`, `parse` (fin à 0 = en cours), `say` ; `CameraGuard` : registre
  `CapabilityAccessManager\ConsentStore\webcam|microphone` par PowerShell, `setBlocked` = `Value` à Deny/Allow (HKCU,
  sans administrateur), `tick` (dans le tour de 15 s de `main.dart`) → alerte « 🚨 <appli> filme » (une fois par appli),
  réglage `app.camera.alerte`). Outils `camera_etat`, `camera_couper` (**action à autoriser**) dans `lifeTools`, phrases
  sans IA (« coupe ma caméra », « qui utilise ma caméra ? », « on me filme ? »), carte `CameraCard` dans
  `ui/security_page.dart`. Le flou n'est pas possible sans pilote de caméra virtuelle : on coupe, c'est plus sûr.
  Tests `test/v176_camera_test.dart`.
- **Il se répare tout seul (v1.61)** : `core/self_repair.dart` (`RepairRules` sans fichiers : `recentLines` (48 h,
  garde les lignes sans date), `diagnose` → `Repair` (micro bloqué ≥ 2 traces → `clicky_reparer_micro`,
  `CERTIFICATE_VERIFY_FAILED` → `TrustedCertificates.install`, « figé » ≥ 3 ou Nexo partout fermé ≥ 3 →
  `Perf.setChoice('leger')`, disque < 2 Go → `pc_ranger_apercu`, JSON abîmé → `AccountSync.syncNow`), `say` ;
  `SelfRepair` : `run({manual})` (une panne réparée n'est retentée qu'à la demande, `app.repare.fait`), branché dans
  `main.dart` (`Perf.later(7, …)` au démarrage, notification « 🔧 Nexo s'est réparé tout seul »), outil
  `clicky_reparer` dans `repairTools`, phrases sans IA (« répare-toi », « tu bugues »)). Il ne supprime jamais rien et
  dit toujours ce qu'il a fait. Tests `test/v177_self_repair_test.dart`.
- **Smily (v1.61, ex-Clicky)** : l'assistant s'était appelé Smily, un smiley qui change d'expression (`ui/clicky/smily.dart` :
  `SmilyMood`, `SmilyRules.moodFor` — ce qu'il **fait** passe avant son humeur —, `SmilyRules.say`, `SmilyFace`). Depuis la
  v1.66 c'est **Nexo** avec un **curseur** (voir plus bas) ; `SmilyMood`/`SmilyRules` servent toujours à choisir son mode.
  Les **noms de code restent** `Clicky*` / `clicky_*` / `Smily*` (classes, outils, clés de réglages, fichiers) : seuls les
  textes vus par la personne changent. Le titre de la fenêtre de l'assistant partout est « Nexo » dans
  `windows/runner/main.cpp` **et** dans `Win.findClicky` / `_perchSpot` : les deux doivent rester d'accord.
- **Il n'insiste plus (v1.61)** : `ui/clicky/patience.dart` (`Answer` oui/plus tard/non/jamais, `PatienceRules.read`
  (« j'ai pas envie », « lâche-moi », « ne me le répète plus »), `silence` (1ᵉʳ refus 6 h, 2ᵉ 2 jours, 3ᵉ **abandon** ;
  « plus tard » = 2 h, « arrête » = abandon direct), `mayTalk`, `ack` ; `Patience` = un **seul** endroit qui retient les
  refus par sujet (`app.patience`), `answered`/`wanted`/`reset`/`droppedSubjects`). Branché dans
  `ClickyController.proposeIdea` (il ne propose plus un sujet refusé) et `answerIdea`, dans `ask` (« arrête » → abandon
  du sujet, même boîte refermée : `_lastSubject`), et dans `Assistant.propose`/`answer` (sujet = `subjectOf(p.id)`).
  Phrase sans IA : « tu peux me reparler de tout » → `reset`. Avant, chaque système relançait dans son coin sans savoir
  que la personne avait dit non : c'est **la** plainte d'Erik sur l'« intelligence ».
- **Notifications plus rapides (v1.61)** : le vrai coupable n'était pas la relève (2 min) mais le regroupement
  (`digest`, 30 min par défaut) qui retenait **tout**. `NotificationCenter.groupable` = la liste de ce qui peut
  attendre (abonnements, colis, jeux, promos, veille, bilans, temps d'écran, synchro, mises à jour) ; `urgent` est
  maintenant l'inverse : une note, un devoir, un message (Discord : l'id est celui du message, sans préfixe), un cours
  annulé, une arnaque, un appel, un guetteur partent tout de suite. Tests `test/v179_patience_test.dart`.
- **Il fait tes devoirs pendant ton absence (v1.61)** : `ui/clicky/homework_auto.dart` (`AutoHomework`,
  `HomeworkRules` : `perDay` 2, `awayAfter` 10 min, `subjectOf` (titre « 📚 Maths : … »), `shouldStart` (autorisé,
  absent, pas déjà occupé, 7 h–23 h), `welcome` (ce qu'il dit au retour, **y compris quand il n'a pas réussi** :
  jamais de faux succès) ; `HomeworkAuto` = autorisation `app.devoirs.auto` (non par défaut), journal
  `app.devoirs.faits` (7 j), `already`/`doneToday`/`record`/`willTell`/`takeWelcome`). Branché : notification
  `devoir:` dans `NotificationCenter.onAny` (`main.dart`) → `ClickyController.onNewHomework` → proposition
  (`ClickyIdea` outil `devoirs_auto`, passe par `Patience`) ou `_startHomework` → `BackgroundTasks.start(goal,
  whenDone:)` (le `whenDone` est appelé aussi quand ça rate) ; le retour est dit dans `welcomeBack` via
  `takeWelcome()`. Interrupteur dans `ui/clicky/settings.dart` (rubrique `teach`). Tests `test/v180_homework_test.dart`.
- **Jeux (v1.62)** : `core/game_pal.dart`. `GameRules.gameOf(exe, path, title, engine)` = un jeu seulement avec un
  **vrai signe** (dossier Steam/Epic/Riot/Xbox/Ubisoft/EA/GOG/Battle.net/Roblox, `knownExe`, `-Win64-Shipping`,
  Unity/Unreal à côté du .exe `GamePal.engineNear`, site de jeux dans le navigateur ; `never` = applis jamais jeux,
  dont Claude/ChatGPT/Notion) : avant, toute appli agrandie inconnue était un jeu (« tu joues à Claude »).
  `GameMode.isGame/tick(path:, title:, engine:)` s'en sert (plein écran en plus). `Win.foregroundPath`. `GamePal` (tour
  de 15 s de `main.dart`) : fiche Steam FR (`storesearch` + `appdetails`) sinon Wikipédia FR, `jeux-infos.json` 30 j,
  `jeu-en-cours.json` (jamais synchronisé) → `GamePal.promptBlock` ajouté à `_sensesBlock` (aider vraiment, pas de
  triche). Outil `jeu_en_cours` (groupe `jeu`).
- **Bouclier d'appel (v1.62)** : `core/call_shield.dart` (`CallRules.callApp/intruders/alert/blurHow` ; `CallShield.tick`
  après `CameraGuard.tick` : une autre appli filme/écoute pendant l'appel → notification `arnaque:appel:` + idée
  `camera_bloquer_appli` (une seule appli : registre `ConsentStore\<cap>\NonPackaged\<clé>`, **action à autoriser**) ;
  début d'appel avec caméra → bulle muette « comment flouter » ; `muteScript` = sourdine du micro par défaut
  (IAudioEndpointVolume en C# via PowerShell, console + communications), outil `micro_sourdine` ; `appel_flou`).
  Le vrai flou n'existe que dans l'appli d'appel (ou les effets de studio Windows) : on ne fait pas de faux flou.
  Phrases sans IA : « coupe mon micro » = sourdine, « coupe ma caméra » = refus Windows, « floute mon arrière-plan ».
  Réglage `app.appel.bouclier`.
- **Mémoire à long terme + rêves (v1.62)** : `ui/clicky/long_memory.dart`. `Memory` (sujet `MemoryRules.topics`,
  poids, `pinned`), `memoire.json` ; `MemoryRules.merge` (sans doublon `same`, la version récente gagne),
  `prune` (oubli : détail vu 1 fois et pas revu 60 j), `relevant` + `promptBlock` (`_memoryBlock` du contrôleur, calculé
  dans `ask`, dans `_system` et `_liveSystem`), `rememberRequest` (« retiens que… », géré dans `ask`), `dreamPrompt` /
  `parseDream` (JSON souvenirs + capacites + reve, secrets filtrés) / `byRules` (sans IA), `dreamDue` (absent ≥ 20 min,
  ≥ 3 messages neufs, 6 h d'écart), `morning`. `ClickyController._maybeDream` (dans `_lifeTick`, Mon Hub seulement) :
  relit `clicky-history.json` + épisodes, IA **locale** = `Ollama.chat` si `Ollama.installed()` sinon règles ;
  `_tellDream` raconte d'abord `takeUntold()`, puis `_offerDreamSkill` → idée `clicky_creer_capacite` (VoiceSkill
  `ask`, **action à autoriser**). `Assistant.remember` écrit aussi dans cette mémoire. Outils `memoire_retenir`,
  `memoire_souvenirs`, `memoire_effacer_souvenir`, `clicky_capacites_perso`. Page `ui/clicky/memory_page.dart`
  (Réglages de Nexo → Sa personnalité → Sa mémoire ; réglage `dreams`, bouclier d'appel). Tests
  `test/v181_jeux_appels_memoire_test.dart`.
- **Version web (v1.63, iPhone sans PC)** : `lib/web/` = **appli à part** (`flutter build web -t lib/web/main.dart`,
  `--no-web-resources-cdn`), car l'appli PC ne compile pas pour le web (win32/FFI/dart:io). **Ne rien importer dans
  `lib/web/` qui touche à `dart:io`, `dart:ffi`, `dart:isolate`** (sinon la construction web casse) ; partagé et
  compatible : `core/online/online.dart` + `spaces.dart` (plus de `dart:io`), `ui/spaces/*` (`defaultTargetPlatform`,
  `SpaceActions.openAccount` réglé par chaque appli : `OnlinePage.open` dans `main.dart`), `ui/hud/hud.dart`,
  `ui/theme.dart`. Publiée par le job `web` du workflow sur **GitHub Pages** (https://shideyx.github.io/mon-hub/, Settings
  → Pages → Source « GitHub Actions » à activer une fois), seulement `SUPABASE_*`/`APP_VERSION`/`UPDATE_REPO` dedans.
  `web/smily.js` (notifications par `smily_sw.js`, partage, .ics, `#lien=`) ↔ `web/phone_bridge*.dart` (export
  conditionnel, `dart:js_interop`). `phone_actions.dart` : `PhoneAction` + `PhoneRules` (sans IA : appeler `tel:`, SMS
  **préparé** `sms:num&body=`, itinéraire Plans, `shortcuts://run-shortcut`, applis par lien, Spotify, minuteur dans
  l'appli, rappel = .ics avec alarme, contacts retenus ; `tools` = fonctions Gemini, `fromTool`) ; chaque action est un
  **bouton** à toucher (rien ne part seul). `PhoneLinkCode` (`MONHUB-TEL:` dans `#lien=`, jamais envoyé au site :
  prénom, clé Gemini, serveur, ≤ 30 souvenirs, ≤ 1 800 caractères) ← `ui/web_version_card.dart` (QR dans
  `PhoneSetupPage`). `account_copy.dart` lit (sans écrire) la copie `SyncBox` du compte en ligne (`p:hub.name`,
  `s:mod.claude.gemini.key`, `f:memoire.json`). `web_smily.dart` (`WebSmily` : règles puis Gemini `gemini-flash-latest`
  avec `PhoneRules.tools`, `geminiOverride` pour les tests, minuteurs, notification des messages d'espaces quand
  l'appli est cachée). Écrans `web_app.dart` (bienvenue 3 choix, onglets Nexo / Espaces / Téléphone / Réglages).
  Notifications quand l'appli est **fermée** : pas encore (il faudra un envoi « push » depuis le Supabase de la
  personne ; `smily_sw.js` sait déjà les afficher). Tests `test/v182_web_test.dart`.
- **Caméra privée + flou du visage (v1.64)** (demande de la personne : peur qu'on pirate sa webcam) : **mode caméra
  privée** dans `core/camera_guard.dart` (`PrivateCamRules.step` sans Windows : appel avec caméra coupée → `ask` une fois,
  après l'appel ou 20 min hors appel → `reblock` ; `CameraGuard.privateMode` = `app.camera.privee`, `setPrivate`,
  `privateTick(call)` appelé dans le tour de 15 s de `main.dart` et quand le Discord intégré change d'état ;
  `inAppCall` = appel dans Mon Hub ; `onPrivateCall` → idée `camera_couper couper=non`), outil `camera_privee` (**action à
  autoriser**). **Flou** : `core/cam_blur.dart` (`CamBlur` : modes `non`/`visage`/`tout`, `app.cam.flou` ; `script` =
  script mis **avant** discord.com dans le Discord intégré (`_PhoneWebView` `initialUserScripts`) : chaque caméra passe
  par MediaStreamTrackProcessor → OffscreenCanvas → MediaStreamTrackGenerator, visage repéré par `FaceDetector`
  (WebView2 lancé avec `--enable-blink-features=ShapeDetection` via `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS`, posé tout
  au début de `main` par `core/cam_blur_env.dart` : **le même pour tous les programmes**, sinon WebView2 refuse) ; visage
  pas trouvé = **toute** l'image floue ; flou impossible avec flou demandé = pas d'image ; changeable en plein appel
  (`liveScript`, bouton `_BlurButton` de la barre d'appel), outil `camera_flou`, phrases `CamBlur.modeFrom`). Seulement
  les appels passés **par Mon Hub** (le Discord normal : son propre flou d'arrière-plan). Le flou ne protège pas d'un
  pirate (il lit la caméra avant) : c'est la caméra coupée qui protège. Testé dans Chromium (caméra factice). Tests
  `test/v183_camera_privee_test.dart`.
- **Sous-titres en continu (v1.64)** : `runCaptionsWindow` envoie le son du PC **en continu** à Gemini Live
  (`LiveCaptions.liveSystem`, `autoVad`, texte = `onOutputText`, ligne finie à `onTurnComplete`, reconnexion ×5) : avant,
  une demande `generateContent` toutes les 8 s épuisait le petit quota gratuit en quelques minutes (« les sous-titres
  marchent pas »). Secours : morceaux `OralCoach.listen(fast: true)` (sans réflexion), puis Whisper après un 429
  (`quotaStatus`).
- **Nexo se connaît et compte ses jetons (v1.65)** (demande de la personne : « qu'il connaisse ses capacités, les
  mises à jour via GitHub, les tokens, qu'il se règle et limite Claude ») : `ui/clicky/self_knowledge.dart`
  (`SelfKnowledge.search` = catalogue `ClickySkills` **+ les vraies actions** branchées, outil `clicky_capacites`
  **toujours envoyé** (`ToolRouter.always`), `promptBlock` dans `_system` et `_liveSystem`) ; `core/whats_new.dart`
  (`WhatsNew` : versions GitHub `releases?per_page=8` (corps = message du commit fusionné → **écrire un message de
  fusion en français clair**, c'est ce que Nexo raconte), `NewsRules.clean`, cache `app.nouveautes`, `afterUpdate` →
  notification « ✨ Mon Hub vX est installé » + `think` une fois (`app.version.vue`), outil `clicky_nouveautes`).
  **Jetons** : `core/token_budget.dart` (`TokenBudget` : `usage` lu dans le flux de `ClaudeApi._call`
  (`message_start` + `message_delta`), le `result` de Claude Code, `usageMetadata` de Gemini (`AiText`, Live) ; `poids`
  = lus + écrits × 5 + cache × 0,05 + mise en cache × 1,25 ; budget `jetons.budget` (200 k par défaut, Réglages de
  Nexo → Outils) ; `TokenRules.level` normal / économe ≥ 50 % / très économe ≥ 80 % / dépassé → `historyTurns` 8/4/2,
  `effort` low (sauf « réfléchis bien »), `geminiFirst` (Gemini répond d'abord, « CLAUDE » s'il lui faut Mon Hub),
  `webAllowed` ; annonce du dépassement une fois par jour ; outils `clicky_jetons`, `clicky_budget_jetons`). **Cache
  Claude** : `_system` = partie fixe, puis `ClaudeApi.momentMark`, puis le moment (heure, écran, situation, mémoire,
  jetons) → `ClaudeApi.systemBlocks` met un point de cache après la partie fixe (avant : l'heure en tête des consignes
  cassait le cache à chaque minute). Ne rien mettre qui change à chaque question **avant** la marque. Tests
  `test/v184_smily_lui_meme_test.dart`.
- **Nexo (v1.66)** — demande explicite de la personne (24 nov. 2026) : « on remet Clicky… on garde le curseur mais un
  meilleur nom, une vraie identité, façon JARVIS », puis « change de nom, un truc cool, utile et simple ». L'assistant
  s'appelle **Nexo** (de *nexus*, le lien ; sans accent, facile à dire et à reconnaître) et c'est de nouveau un
  **curseur** : **la Pointe** (`ui/clicky/identity.dart` : `Nexo` = nom, devise, `lore`, couleurs violet #7C5CFF /
  rose #E0457B, `modeFor(SmilyMood)` ; `NexoPointer` + `NexoPainter` = flèche à deux faces, liseré clair, **noyau** qui
  montre l'état — écoute (pulse avec la voix), réflexion (arc qui tourne), parole, action (pointe allumée), travail
  (pastille), sommeil/concentration (atténué) ; animation **seulement** dans les modes actifs `Nexo.animated`). Dessin
  original (pas le triangle bleu d'un autre produit) : ne pas revenir au smiley. Persona façon majordome numérique
  (`clickyPersona`, calme, précis, pince-sans-rire, « C'est fait. »). Mot de réveil `WakeWord.phrases` = nexo / nexos /
  nekso (+ anciens noms en alias) ; les regex qui retirent le nom en tête de phrase contiennent `nexo|nexos|nekso|nexou`.
  Visite guidée : `NexoPointer` à la place de l'ancien « réacteur ».
- **Installation pour de bon + connexions gardées (v1.66)** : la personne lançait Mon Hub **depuis l'intérieur du zip**
  (WinRAR → `AppData\Local\Temp\Rar$…`), et WebView2 rangeait le profil (connexions Discord, Instagram, Google…) à côté
  du programme → perdu à chaque zip (« trop chiant de se connecter »), et une copie de plus à chaque fois.
  `core/install.dart` (`AppInstall`) : `useStableWebData` (tout début de `main`, **tous** les programmes) pose
  `WEBVIEW2_USER_DATA_FOLDER` = `%LOCALAPPDATA%\MonHub\WebView2` ; `migrateWebData` recopie une fois l'ancien
  `hub.exe.WebView2` (sans caches ni verrous, `worthCopying`) ; `moveIfTemporary` (`decide` / `isTemporary` : Temp,
  Rar$, 7z, Téléchargements) installe dans `%LOCALAPPDATA%\Programs\Mon Hub` (`version-monhub.txt`, copie via
  `Updater.replaceInPlace`) ou ouvre la copie installée plus récente, relance avec `--relance`, `exit(0)` ; `stamp`.
  Rien n'est jamais supprimé. Les raccourcis se réparent seuls (`AppShortcuts.ensure`).
- **Une seule copie (v1.66)** : `windows/runner/main.cpp` : mutex `Local\MonHub.Principal` (un widget :
  `Local\MonHub.Widget.<id>`) ; deuxième lancement = la fenêtre déjà ouverte revient devant (`SetPropW`
  `MonHubFenetrePrincipale` + `EnumWindows`) ; `--updated` / `--relance` attendent 15 s que l'ancienne copie parte.
  L'assistant partout garde son verrou Dart (port 47613).
- **Notifications instantanées (v1.66)** : `NotificationCenter.pollNow` relève les modules **en même temps** (avant : un
  par un, un module lent bloquait tout et figeait l'appli), limite `pollTimeout` 25 s, pas de relève en double
  (`_inFlight`), `pollAfter` (`argent` attend `mail`, même connexion), `pollModules(ids)` = relève immédiate, relève
  demandée pendant une autre = faite juste après. `core/web_notify.dart` (`WebNotify` : `shimScript` = relais de l'API
  `Notification` mis avant le site, `statusScript`, `countInTitle`, `news`). **Discord** : le Discord caché
  (`DiscordPhone`) porte le relais ; un non-lu de plus dans son titre ou une notification relayée → `onActivity` →
  `pollModules({'discord'})` (≤ 2–4 s au lieu de 2 min, au plus 1 relève / 3 s). **Instagram** :
  `modules/instagram/instagram_watch.dart` (`InstagramWatch` + `InstagramWatchLayer` dans le builder de `HubApp`) =
  instagram.com/direct/inbox/ ouvert **caché** comme un onglet (`quietScript`, son/micro refusés), titre lu toutes les
  3 s → `onNews` → notification `insta:` + pastille du module ; page de connexion → rechargée toutes les 10 min ou en
  quittant la page Instagram. **Toujours aucune requête automatique ni API privée Instagram** : rien de plus qu'un onglet
  ouvert. Réglage propre au PC `app.instagram.direct` (oui par défaut).
- **Lag (v1.66)** : la garde caméra/micro lit le registre par FFI (`CameraGuard._readRegistry` : RegGetValue /
  RegOpenKeyEx / RegEnumKeyEx) au lieu de lancer PowerShell toutes les 30 s (PowerShell = secours), et ne redessine que
  si ça change. Bulle de l'assistant : `TypedText.nextCut/safePrefix` ne coupe plus un émoji en deux (« string is not
  well-formed UTF-16 », plantage vu dans le journal). Tests `test/v185_nexo_test.dart`.
- **Nexo t'annonce tes messages (v1.66)** : `ui/clicky/announce.dart` (`MessageAnnounce.messageOf/line` sans IA :
  Discord « Discord · X », Instagram `insta:`, espaces `espace:`, mails, École Directe `msg:` ; jamais les codes /
  mots de passe `secretLike` ; appel `discord-appel` → « 📞 X t'appelle… Dis « décroche » ») + `AnnouncePacer` (une
  bulle / 20 s, la rafale est comptée). Branché au début de `ClickyController.reactTo` (`_announceMessage` : rien en
  jeu, concentration, appel, plein écran) → `think(aloud: announceAloud)` ; un appel est toujours dit. Réglages
  `announce` (oui) / `announceAloud` (non) dans la rubrique `topo` (« Annonces et topos »). Phrases sans IA
  `QuickAnswers.callAction` : décroche (en vidéo), refuse l'appel, raccroche → outil `discord_appel`.
  **Bug corrigé** : `think(aloud: false)` envoyé à Nexo partout devenait parlé (`think64` sans le mode) → `thinkq64`.
  Salutation du jour + `HubFeed.say` (la chose importante du moment). `selfAnswer` : « pourquoi tu t'appelles
  Nexo ? » → `Nexo.lore`.
- **Réglages remis d'aplomb (v1.66)** : un seul prénom (`callName` vide → `hub.name` des Réglages → prénom du compte) ;
  « Dis Nexo » dans L'essentiel ; Apparence = « Tête haute / Simple » (l'ancien texte parlait d'un réacteur bleu qui
  n'existe plus) ; couleurs des fenêtres de Nexo = violet/lavande (`hudCyan` garde son nom) et `clickyBlue` = violet ;
  déconnexion confirmée ; bouton « Supprimer » en rouge ; listes déroulantes qui ne plantent plus sur une valeur hors
  liste ; « Redémarrer Mon Hub maintenant » dans Vitesse (`AppInstall.restart`, `--relance`) ; l'import de
  configuration garde les nombres à virgule.
- **Cerveau économe (v1.66)** (demande : « tout ne doit pas passer par Claude, trop de jetons ») :
  `core/gemini_agent.dart` (`GeminiAgent.ask` = Gemini `generateContent` avec `functionDeclarations` des outils
  `ToolRouter.pick`, boucle ≤ 5 tours, même permission que Claude (`isWriteAction` + `confirmAction`), résultats
  `PromptShield.wrap` + `ToolRouter.cap`, « CLAUDE » = passer la main ; `BrainRules` : `econome` (défaut : Gemini sauf
  gros travail `ClaudeThrift.heavy`, `deep`, écran, documents) / `equilibre` (l'ancien) / `claude`). Branché dans
  `_thriftAnswer` (réglage partagé `economie`, choix dans L'essentiel).
- **Coach de jeu en direct (v1.66)** : `ui/clicky/game_coach.dart` (`GameCoach` : Gemini Live avec **images en flux**
  `GeminiLive.sendVideo` (JPEG 768 px qualité 60 toutes les 2 s, `mediaResolution: MEDIA_RESOLUTION_LOW`) — pas des
  captures envoyées à Claude ; conseil de lui-même toutes les 25 s (`CoachRules.tipPrompt`, « RIEN » = son retenu puis
  jeté : `_hold`) ; Ctrl + Alt = `talkStart/talkEnd` (branché au début de `startListening/stopListening`), questions
  écrites → `ask` (dans `ClickyController.ask`, après les réponses sans IA) ; images seulement quand le jeu est au
  premier plan, arrêt seul après 4 min sans jeu ; outil local `jeu_coach`, phrases `CoachRules.command`). Les jeux en
  plein écran **exclusif** peuvent donner une image noire (capture GDI) : ceux en « plein écran fenêtré » marchent.
- **Micro (v1.66)** : le bouclier d'appel prenait pour des espions une autre appli d'appel, les **jeux** (chat vocal),
  le Discord intégré (`msedgewebview2` → « Mon Hub ») et Nexo qui guette son nom (`powershell` → « Nexo (PowerShell) »)
  → « couper son accès » coupait le micro pour de bon. `CallRules.intruders` les exclut (`isGame` par le chemin de la
  clé). `CallShield.giveMicBack` (sourdine levée, accès rendu aux applis d'appel / jeux / Mon Hub / celles que Nexo a
  bloquées, retenues dans `app.micro.bloques`), `repairOnce` au démarrage (une fois, notification), `muteReminder`
  (sourdine mise par Nexo `app.micro.sourdine.nexo`), outil `micro_rendre`, phrases « on ne m'entend plus », Ctrl + Alt
  + M (`toggleMute`, Nexo partout). Le registre lit aussi `Value` par appli (`SensorUse.denied`).
- **Flou (v1.66)** : mode `fond` dans `CamBlur` (arrière-plan flou, tête et épaules nettes ; pas de visage = tout
  flou), « floute mon arrière-plan ». Toujours seulement les appels passés par Mon Hub (pas de caméra virtuelle sous
  Windows 10).
- **Appels Instagram (v1.66)** : `HubWebView.userScripts` (scripts mis avant le site, aussi dans les fenêtres
  `_PopupWindow`, qui autorisent maintenant caméra et micro : avant, la fenêtre d'appel ne répondait pas aux demandes)
  → `InstagramPage` y met `CamBlur.script` + bouton « Flou » dans sa barre (`liveScript` en plein appel).
  Ctrl + Alt + M marche pour tous les appels. **Modèle Claude économe** : sans modèle choisi, `ClaudeApi.model` =
  Sonnet en mode `econome` (Opus seulement si `ClaudeApi.deep`, « réfléchis bien ») ; Claude Code : `--model sonnet`
  (réglé dans `_askAi`).
- **Les robots de Nexo (v1.66)** (demande : « plein de petits robots que Nexo utilise et crée, proactif de dingue sans
  jetons ») : `ui/clicky/robots.dart`. `Robot` (déclencheur `heure` / `appli` / `jeu` / `retour` / `message` / `note` /
  `demarrage` / `usage` + actions `phrase:` (exécutée **sans IA** par `ClickyController.robotPhrase` = `QuickAnswers`,
  sinon Gemini `GeminiAgent`, **jamais Claude** ; Nexo partout : `ClickyDesktop.ask`), `dire:`, `notifier:`,
  `protocole:` ; `ask` = proposer d'abord, `perDay`). `RobotRules` sans IA : `parse` (« quand j'ouvre Discord, coupe
  mon micro », « tous les jours à 19 h, … », « le samedi à 10 h 30, … », « toutes les 45 minutes, … »), `looksLikeRobot`,
  `firesOnTick` (transitions : appli qui **arrive**, jeu qui **commence**, retour après absence ; heure dans les 3 min,
  une fois), `firesOnNote`, `templates` (robots tout prêts ; `byDefault` allumés d'office : devoirs 19 h, programme de
  demain 21 h, coach quand tu joues (demande), pause des yeux). `Robots` (`robots.json`, synchronisé) : `tick` (tour
  de 15 s de `main.dart`), `onNotification` (`NotificationCenter.onAny`), `_maybeSuggest` (un modèle proposé par jour
  via `proposeIdea` → outil `robot_installer`), outils `robot_creer/liste/supprimer/activer/installer/lancer` (dans
  `lifeTools`), phrases sans IA dans `QuickAnswers` (création, « mes robots »). Page `ui/clicky/robots_page.dart`
  (Réglages de Nexo → Ce qu'il fait pour toi → Ses robots). Tests `test/v186_robots_test.dart`.
- **Boîte de Nexo plus pratique (v1.66)** : `_QuickActions` (boîte ouverte sans réponse : fais le point, devoirs,
  prochain cours, ce que j'ai raté, musique, coach, robots, micro — tout sans IA), `_BrainPill` (qui a répondu :
  `ClickyController.lastBrain` = sans IA / Gemini / Claude), bouton copier, boîte 420 × 460.
- **Il sait quand tu as cours (v1.67)** (demande : « qu'il comprenne quand j'ai pas cours, que tout communique mieux ») :
  `core/school_calendar.dart`. `SchoolRules` sans IA ni réseau (testables) : jours fériés calculés (`easter`,
  `publicHolidays`, lundi de Pentecôte compris), zones (`zoneFromPostcode` / `zoneFromRegion` / `zoneFromText` /
  `zoneFromPlace` = géocodage Open-Meteo, déjà utilisé pour la météo), `builtIn` = calendrier 2026-2027 (arrêté du
  22 oct. 2025 ; hiver/printemps par zone) pour marcher sans internet, `parseOfficial` = data.education.gouv.fr
  (« fr-en-calendrier-scolaire », dates UTC → jour de Paris, `population` Enseignants ignorée, été sans fin =
  `approxEnd`), `fromAgenda` = congés vus dans École Directe, `merge` (ED > officiel > intégré). `classify` → `SchoolDay`
  (`cours` / `weekend` / `vacances` / `ferie` / `annule` / `libre` (jour vide alors que la semaine a des cours) /
  `inconnu`), `lateStart`, `earlyEnd`, `gaps` (midi repéré), `freePeriods` ; `moment` → `SchoolPhase` (avant, enCours,
  pause, trou, midi, fini, pasCours) ; `nextSchoolDay` (la rentrée), `nextBreak`, `schoolDaysBetween`, `cancelImpact`
  (« Tu commences à 9 h au lieu de 8 h », « 1 h de libre ») ; `SchoolReport` (`sayToday`, `sayNextDay`,
  `sayNextBreak`, `backTomorrow`, `breakStarts`, `promptBlock` = consignes « Adapte-toi », `toJson` avec `contexte`).
  `SchoolCalendar` : zone `hub.ecole.zone` (synchronisée, devinée d'après la ville du Carnet sans écraser un choix),
  officiel relu 1×/semaine (`app.vacances.<zone>`, seule la zone est envoyée), `last` = dernier point pour une réponse
  immédiate (`hasClassOn`, `inClassNow`), `fetchOverride` pour les tests. École Directe : `EdLesson.kind` (typeCours :
  **CONGE ≠ cours**), `exempt` (dispensé), `changed`, `isBreak` ; `EcoleDirecteModule.agendaMap` ; notification
  `annule:` avec ce que ça change. Agenda : `AgendaItem.holiday/exempt`, `agenda_lire` → `vacances` / `dispense`,
  outils **`agenda_ecole`** (le point, ou un jour `date`) et **`agenda_vacances`** (liste, `zone` pour la régler),
  `ScheduleModule.schoolReport` (cours d'ED déjà chargés seulement : pas de connexion de plus). **Tout communique** :
  « Ton fil » (`HubFeed.schoolItems` : reprise demain, bonnes vacances, pas cours, on commence plus tard, heure de
  libre, plus que N jours), `ClickySituation` (bloc école en tête des consignes Claude / Gemini / Live ;
  `inClassUntil`), briefing du matin (pourquoi pas de cours, vacances qui approchent), sac (« Demain, c'est la
  reprise »), coucher et sac ignorent les congés (`SchoolRules.isLesson`), **robots** `Robot.school` = '' / `ecole` /
  `veille` / `libre` (`RobotRules.schoolOk`, `schoolFrom` « les jours de cours », « pendant les vacances » ; modèles
  devoirs 19 h / programme 21 h / coucher = `veille`, les anciens robots la reprennent de leur modèle ;
  `Robots.schoolDay` = `SchoolCalendar.hasClassOn` dans `main.dart`), initiatives (`Autonomy.rules` : `ecole`,
  `libre_min`, `demain_cours` → heure de libre = revoir ses cartes, briefing 9–12 h sans cours), phrases sans IA
  (`QuickAnswers.schoolAnswer` : j'ai cours demain ?, vacances (de Noël…), rentrée, je finis / commence à quelle heure,
  j'ai un trou, c'est férié, ma zone ; « prochain cours » pendant les vacances = la reprise), « j'habite à Lyon » →
  zone. **Discret pendant les cours** (`quietInClass`, partagé, oui par défaut) : `think(aloud)` muet en classe.
  Tests `test/v187_ecole_test.dart`.
- **Parler à Nexo façon JARVIS, gratuit (v1.67)** (demande : « lui parler sans exploser mes tokens, gratuit, bonne
  qualité audio, une voix qui ne change pas ; pas en local sauf si ça marche vraiment bien ») — on reste sur **Gemini
  Live** (clé gratuite, en ligne ; pas de Whisper/Piper local). `ui/clicky/jarvis_talk.dart` : `JarvisTalk` =
  conversation mains libres (une connexion `GeminiLive(autoVad: true, temperature: 0.6)`, micro ouvert, outils de Mon
  Hub par Gemini = **aucun jeton Claude**, reprise après `goAway` (`onGoAway`, même session), arrêt après 45 s de
  silence / « merci Nexo, c'est tout » / Échap / quota) ; `TalkRules` sans micro (`isStart` « on discute », « mode
  conversation », `isStop`, `isGoodbye`, `gate` : micro coupé pendant sa voix + écho 350 ms, **couper la parole** =
  voix forte nettement au-dessus de la sienne 3 morceaux de suite). Contrôleur : `startTalk` / `stopTalk` / `talking`,
  phrases interceptées au début de `ask`, outil local `clicky_conversation`, bouton « Discuter » (`_QuickActions`) et
  dans Réglages de Nexo → Voix. **Voix toujours identique** (`voiceSteady`, partagé, oui par défaut) :
  `ClickyVoice.steady` lit tout par `LiveReader` (même moteur `GeminiLive.workingModel` et même voix que la
  conversation, température 0,3), la synthèse Gemini (≈ 15 lectures/jour, autre son) n'est plus qu'un secours ;
  `GeminiLive.voiceStyle` (ton posé, accent neutre, jamais de changement) dans toutes les consignes vocales.
  **Son sans coupures** : `PcmJitter` (pcm_player.dart) = 200 ms d'avance après un silence, octets pairs, montée douce
  5 ms ; `PcmPlayer.flush()` en fin de tour. Tests `test/v188_jarvis_voix_test.dart`.
- **Il joue à ta place (v1.67)** (demande : « je lui dis ouvre mon inventaire, craft-moi une pioche sur MC et il le
  fait ») : `ui/clicky/game_agent.dart` (`GameAgent.run` : capture de la fenêtre du jeu (`Win.captureScaled`, 1280 px,
  JPEG) → **Gemini Flash** (`generateContent`, JSON, gratuit, jamais Claude ; `askOverride` pour les tests) → 1 à 4
  actions → exécutées → nouvelle capture ; 25 tours au plus ; arrêt : Échap maintenu, Ctrl + Alt, changement de
  fenêtre ; `GameInput.releaseAll` à la fin) ; `GameAgentRules` sans Windows (`isRequest` (verbes de jeu, « sur mc,
  … » ; une question reste une question), `blocked` = jeux en ligne avec anti-triche (Valorant, Fortnite, CS2,
  **Roblox**, LoL…) → **refus**, coach seulement, `playbook` Minecraft (touches, inventaire 2×2 / table 3×3, recettes,
  /give en créatif), `guide`, `parse` (bornes ; « commande » seulement si elle commence par « / » : jamais de message
  aux autres joueurs), `toScreen` (0–1000 → écran)). `ui/clicky/game_input.dart` : `GameKeys` (codes **scan**
  physiques : avancer = 0x11 = Z en AZERTY / W en QWERTY, chiffres de la barre), `GameInput` (SendInput
  `KEYEVENTF_SCANCODE`, `hold`, `look` = souris **relative** (caméra), `clickAt` (+ petit mouvement, Maj + clic),
  `holdButton`, `drag`, `azerty`). Branché : début de `ClickyController.ask` (`playGame`), outil local `jeu_agir`
  (Claude, Gemini, conversation en direct), **le coach de jeu Live** l'appelle (`GameCoach.actTool`, `canAct` dans
  ses consignes ; ses conseils se taisent pendant que l'agent joue), groupe `jeu` du `ToolRouter`, Échap = `cancel`.
  Tests `test/v189_agent_jeu_test.dart`.
- **Le téléphone pilote le PC, en mieux (v1.67)** : `PhoneLink` (routes `api/ecran?l=` = JPEG de l'écran principal,
  `api/nexo` = question → `ClickyController.askFromPhone` (même chemin que `ask`, mais **pas de voix sur le PC**
  (`_phoneAsk` dans `speak`) ni Gemini Live ; la réponse revient au téléphone), `api/applis?q=` (`PcApps`),
  `api/fenetres`), `PhoneRemote` (`capture`, `clic_ecran` x,y en 0..1 → `toScreen`, `taper`, `touche` (combinaisons
  validées), `lancer`, `fenetre`). Page `assets/phone/` : onglets **Nexo** (bulles, dictée du navigateur
  `webkitSpeechRecognition` fr-FR, réponse lue par `speechSynthesis` si coché), **Écran** (image rafraîchie ~4/s,
  toucher = clic, appui long = clic droit, double touche = double-clic, 2 doigts = défiler, clavier du téléphone en
  direct, fenêtres, Net/Rapide), Télécommande (+ écrire sur le PC, touches, applis). CSS : `[hidden]` gagne toujours.
  Testé dans Chromium (faux PC). Tests `test/v190_telephone_plus_test.dart`.
- **La voix du PC, sans Gemini (v1.68)** (demande : « que la voix marche nickel même sans API Gemini » ; voix de
  Windows/Edge toujours **interdites**) : `ui/clicky/piper_voice.dart` (`PiperVoice` = **Piper**, voix neuronale libre
  sur le PC : programme `piper_windows_amd64.zip` 2023.11.14-2 de GitHub avec **SHA-256 épinglée** (`zipSha256`), voix
  `voices` tom (défaut, homme) / siwis / pierre (upmc, `speaker` 1) depuis Hugging Face `rhasspy/piper-voices` v1.0.0,
  **secours** siwis depuis GitHub v0.0.2 (tar.gz, SHA-256 épinglée) si Hugging Face ne répond pas ; dans
  %APPDATA%\MonHub\piper ; `Whisper.download/unzip` réutilisés ; `autoInstall` une fois en fond au démarrage
  (`Perf.later(9)` dans `main.dart`, `app.piper.auto` = false pour refuser, échec retenté après 1 j), notification ;
  synthèse : programme **gardé ouvert** `--json-input --output_dir` (une ligne sur sa sortie = une phrase prête), lancé
  en `detachedWithStdio` (pas de fenêtre ; **jamais lire `exitCode`** : la fin = sortie fermée), sinon repli
  `_noPersist` = un lancement par phrase `--output_file` ; texte en JSON **ASCII** (`jsonLine`, accents en \uXXXX),
  `speakable` sans émojis/Markdown, `lengthScale` d'après la vitesse). Branché dans `ClickyVoice` (`engine` : `auto` =
  Gemini puis PC, `pc` = toujours le PC, `gemini` ; `_piperFirst`, `_speakPiper` avec morceau suivant préparé, relais
  après chaque échec Gemini), réglage partagé `voiceEngine` (`liveReady` faux en `pc`, sinon Gemini Live parlerait
  avec sa voix), panneau `_PiperSettings` (Réglages de Nexo → Voix : installer, choisir, écouter). **Conversation sans
  Gemini** : `startTalk` → `_startHandsFree` (écoute de Mon Hub + voix du PC + conversation continue sans limite de
  tours, `_handsFree`, 12 s de silence ou « merci Nexo, c'est tout » pour finir) ; quota épuisé en pleine
  conversation Live → bascule toute seule. Programme téléchargé **jamais exécuté ici** (refusé par la sécurité de Claude
  Code) : le protocole a deux chemins pour ne dépendre d'aucune supposition. Tests `test/v191_voix_pc_test.dart`.
- **Publier sans session** : si `gh` n'est pas connecté, `scratchpad/publish.ps1` (robot : code de connexion GitHub
  renouvelé dans le presse-papier, push, PR + fusion par `gh api`, attente de la version, installation dans
  `%LOCALAPPDATA%\Programs\Mon Hub` + recopie du profil WebView2) ; envoyer le code ailleurs (hébergeur, artefact)
  est refusé par la sécurité de Claude Code.
- Vérifier ici sous Windows : `dart analyze --fatal-infos` (pas `flutter analyze`, qui se perd dans le SDK quand il est
  dans un chemin long) ; 4 tests de l'accueil échouent **seulement sous Windows** (PowerShell de `PcApps.load` →
  minuteur en attente, texte « PC (Windows) ») : sous Linux (GitHub) ils passent.
