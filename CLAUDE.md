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
- Clicky « conscient » façon heyclicky/JARVIS (v1.44) : `ui/clicky/mind.dart` (`ClickyMind` : humeur `moodAt`, lien `bond`,
  souvenirs `Episode` — conversation, émotion, **attente** = « j'ai un oral jeudi » repéré par `DateSpotter`, il prend des
  nouvelles ensuite (`dueLoops`, salutation) —, `promptBlock` dans les consignes Claude et Gemini Live, `selfAnswer` sans IA
  (« ça va ? », « es-tu conscient ? » → honnête : simulation), `thought` (pensées par règles), quotas voix 4/j et remarques
  8/j). Réglages → Conscience de Clicky (`mind_page.dart`). Persona heyclicky dans `clickyPersona` (hud.dart).
- Présence : `ClickyController._presenceTick` (toutes les 2 s) : regards autour quand la souris ne bouge plus (`glance`,
  `gaze/gazeNote`, `lookSpots` = fenêtre au premier plan, horloge, autre écran), remarques spontanées `noticeSomething`
  (Gemini vision, jamais Claude ; jamais en plein écran `Win.foregroundFullscreen`, ni sur `privateApp`, ni sur Mon Hub),
  `think()` (rappels de l'assistant dits par Clicky ; `think64`/`notice` envoyés à Clicky partout). Vol = `flight.dart`
  (`ClickyFlight` : arc, 0,26–0,75 s selon la distance, orientation `angleAt`, taille 1,3 au milieu ; `springTowards` pour
  suivre la souris), `flightPose` ; il parcourt la fenêtre pendant qu'il réfléchit (`_scanStep`) et part vers la cible
  avant de viser précisément. Bulle qui rebondit et s'écrit (`TypedText`).
- Clicky **autonome** (v1.45) : `ui/clicky/autonomy.dart` (`ClickyIdea`, `Autonomy.allowed` / `never` = jamais envoyer un
  message, supprimer, lancer une commande ; `prompt` Gemini JSON, `parse`, `rules` sans IA, `answer` « oui/non » à la voix).
  `ClickyController.startAutonomy` (Mon Hub, toutes les minutes) → `autonomyTick` (présent = `Win.idleSeconds` < 2 min,
  pas en plein écran, rythme `ClickyMind.ideaAllowed` : rarement/normal/souvent) → `decideIdea` → `proposeIdea` (boîte de
  Clicky avec Oui / Non / Plus tard `_IdeaButtons`, à l'oral ; envoyée à Clicky partout par `idea64`) → `answerIdea` →
  `_runIdea` (outil direct, ou `agent` = `_runAgent`). Il apprend (`recordDecision`, `likes/dislikes`, `skipTools` après 2
  refus). Retour après 20 min d'absence : `welcomeBack`. Outil `assistant_ajouter_plan_journee` (ajoute le plan, avec accord).
- Lecture dans la Bibliothèque (v1.46) : `modules/books/read_finder.dart` (`ReadFinder` : titre nettoyé `ReadQuery.parse`
  — « Tome 3 », « chapitre 12 », sous-titre —, recherche en parallèle MangaDex (scans, fr puis en, `contentRating` safe/
  suggestive seulement), Projet Gutenberg via gutendex (texte) et Internet Archive (accès **libre** seulement, pas
  d'emprunt) ; `confident` = ressemblance du titre ≥ 0,95 sinon « C'est celui-ci ? » ; `pickChapters` un chapitre par
  numéro ; chapitres officiels `externalUrl` ouverts dans le navigateur). `Book.read` = `ReadLink` (source, chapitre,
  page). Lecteurs : `modules/books/reader_page.dart` (`openReading`, `ScanReaderPage` page par page / webtoon / sens
  japonais, `TextReaderPage` liseuse avec texte gardé dans `lectures/`, `WebBookPage`). Outil Clicky `livre_ou_lire`.
  Jamais de site pirate ni de scraping : seulement ces API publiques.
- **Sécurité (v1.47)** : `SECURITY.md`. Pont local (`claude_bridge.dart`) : clé 64 hex comparée en temps constant
  (`sameKey`), refus des pages web (`fromThisPc` : Origin / Host), corps limité (`maxBody`), `/call` demande l'accord
  pour les actions d'écriture (sauf Clicky partout qui l'a déjà demandé : en-tête `x-monhub-client: clicky` +
  `confirme`). **Jamais `cmd /c start`** : `core/safe_open.dart` (`SafeOpen.launch` = ShellExecute, `risky` → accord
  via `PcControl.confirmRisky`). `PcControl.secretPath` (mots de passe, cookies, clés : jamais lus/écrits),
  `riskyWrite` (démarrage, scripts : toujours demandés), `dangerous` élargi. Bouclier anti-piège
  `core/prompt_shield.dart` (`wrap` = résultats d'outils extérieurs étiquetés « données », `tainted` 15 min → le mode
  auto redemande, `rule` dans les consignes Claude et Gemini Live). `ErrorLog.redact` (clés masquées). Mise à jour :
  empreinte SHA-256 obligatoire + `Updater.trustedUrl`. Workflow : `permissions: contents: read`, Dependabot.
- **Clicky économe** : `core/tool_router.dart` (`ToolRouter` : groupes d'outils par mots-clés, `pick`, méta-outils
  `mon_hub_outils` / `mon_hub_action` résolus par `resolve` pour garder les permissions, `cap` des résultats ;
  `/mcp?groupes=`), `ui/clicky/thrift.dart` (`ClaudeThrift.light` → Gemini, `heavy` → effort medium sinon low,
  `ClaudeUsage` compteur local), `cache_control` dans `ClaudeApi`, réglage `thrift`. Modèle conseillé : Claude Opus 5.5
  (`claude-opus-5-5`).
- **Ton fil** (modules reliés) : `core/hub_feed.dart` (`HubFeed.build` sans IA à partir des outils de lecture
  agenda/devoirs/révisions/livres + pastilles ; `say` pour Clicky), `ui/hub_feed_view.dart` (`HubFeedStrip` à
  l'accueil). Clicky proactif : `ClickyController.feedNudge` (1 info importante, ≤ 6/jour, 45 min d'écart) + retour.
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
  `HubController.reload`, Clicky). **PC principal hors de portée** : le nouvel appareil dépose `demande-compte-<id>.json`
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
