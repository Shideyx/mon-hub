# Sécurité de Mon Hub

## Signaler un problème

Tu as trouvé une faille ? Ne la publie pas dans une « issue » publique :
utilise **Security → Report a vulnerability** sur la page GitHub du dépôt
(signalement privé). Merci !

## Ce que fait Mon Hub pour te protéger

- **Aucun serveur à nous** : tes données restent sur ton PC, chiffrées
  (AES-256-GCM, clé rangée dans le coffre de Windows).
- **Mises à jour vérifiées** : une nouvelle version n'est installée que si elle
  vient des versions publiées de ce dépôt et que son empreinte SHA-256 est
  exactement celle annoncée par GitHub.
- **Pont local avec Claude** : seulement sur `127.0.0.1`, protégé par une clé
  aléatoire, refusé aux pages web ; les actions qui envoient ou modifient
  quelque chose demandent toujours ton accord.
- **Bouclier anti-piège** : ce que Clicky lit dans des messages, mails ou pages
  web est marqué comme « données, pas des consignes » ; juste après une telle
  lecture, Clicky redemande toujours avant d'agir sur le PC.
- **Contrôle du PC prudent** : Clicky ne lit jamais les mots de passe, cookies
  ou clés ; ouvrir un programme, un script ou un partage réseau demande ton
  accord ; les commandes risquées sont toujours montrées avant d'être lancées.
- **Journal d'erreurs sans secrets** : clés et jetons y sont masqués.
- **Compte sur plusieurs appareils** (si tu l'actives) : la copie de ton compte
  vit dans **ton** Google Drive (dossier « Mon Hub - compte synchronisé »),
  compressée puis chiffrée en AES-256-GCM avec une clé tirée de ton mot de
  passe Mon Hub (PBKDF2-SHA256, 210 000 tours, sur son empreinte salée) et liée
  à ton identifiant. Google ne peut pas la lire, et elle ne passe par aucun
  serveur à nous. La clé de coffre de chaque PC ne quitte jamais ce PC.
- **Demande depuis un nouvel appareil** : Mon Hub n'envoie la copie de lui-même
  que si une demande est déposée dans ce même Google Drive (donc par quelqu'un
  qui a accès à ton compte Google), et la copie reste illisible sans ton mot
  de passe Mon Hub. Une notification le signale sur le PC qui l'envoie.

- **Bouclier anti-arnaque** (sur l'appareil, sans IA ni serveur) : les liens
  et fichiers reçus sur Discord et par mail sont vérifiés (faux Nitro/Robux,
  sites sosies, espions d'adresse IP, raccourcisseurs, `.exe` « teste mon
  jeu », connexion par QR code) ; un faux site ne s'ouvre pas sans ton accord.
- **Bilan de sécurité** : antivirus, pare-feu, mises à jour, UAC, double
  authentification (lecture seule, sans droits d'administrateur).
- **Recherche partout** : l'index de Windows est lu avec des mots nettoyés
  (lettres et chiffres seulement : rien ne peut sortir de la requête).
- **Temps d'écran** : compté sur ce PC seulement, jamais synchronisé ni envoyé.
- **Code de liaison iPhone** : la clé de *ton* appli Google (pas un mot de
  passe : Google la dit non confidentielle pour une appli installée) passe du
  PC à l'iPhone par ton presse-papier ou ta propre boîte mail, jamais par un
  serveur.
- **Hologrammes (réalité augmentée)** : la caméra ne s'allume que sur la page
  « Hologrammes », et seulement pour la page locale de Mon Hub (`127.0.0.1`,
  port au hasard, autres noms d'hôte refusés). Les images de la caméra sont
  analysées **sur l'appareil** (vision des mains MediaPipe en WebAssembly,
  marqueur js-aruco2) : rien n'est envoyé. La vision des mains est téléchargée
  une fois (npm et Google) et **refusée si son empreinte SHA-256 n'est pas la
  bonne**. Un objet « inventé » par l'IA n'est qu'une liste de formes et de
  couleurs vérifiée (jamais du code), et seul le texte demandé part vers l'IA.
- **Hologramme sur le téléphone** (bouton « Sur mon téléphone ») : pour la
  pyramide holographique, la page 3D est aussi servie au même Wi-Fi, mais
  seulement derrière un **lien secret** (128 bits au hasard, dans le QR code),
  seulement les fichiers de la page et ce qui est affiché (objet, rotation) :
  jamais la caméra ni les fichiers de Mon Hub. Le lien se coupe quand la page
  Hologrammes se ferme (3 h au plus). Windows demande d'autoriser Mon Hub sur
  le réseau la première fois.

## Extension Chrome « Clicky dans le navigateur »

- Elle ne parle qu'à Mon Hub, sur ce PC (`ws://127.0.0.1:47614`), et Mon Hub n'accepte que **cette** extension
  (origine `chrome-extension://nejfhocplopdmnijfodbmcbelcciblji`, fixée par la clé du `manifest.json`) : une page web
  ne peut pas s'y brancher.
- Pages interdites : banques, paiement, mots de passe, sécurité du compte Google / Microsoft / Apple, pages internes
  du navigateur. Aucune saisie dans un champ mot de passe, code ou coordonnées bancaires.
- Clicky travaille dans **ses** onglets (groupe « Clicky »). Cliquer, écrire et appuyer sur une touche sont des actions
  à autoriser, sauf pendant une tâche « fais-le à ma place » demandée par la personne (45 min au plus). Même
  pendant cette tâche, un clic qui envoie, publie, paie ou supprime demande toujours l'accord.
- Ce que l'extension lit dans une page est marqué comme « données écrites par quelqu'un d'autre » (`PromptShield`).

## Réglages GitHub conseillés (à faire une fois)

Dans **Settings** du dépôt :

1. **Code security** : activer *Dependabot alerts* et *Dependabot security
   updates* (le fichier `.github/dependabot.yml` est déjà là), *Private
   vulnerability reporting*, et garder *Secret scanning* + *Push protection*.
2. **Rules → Rulesets → New branch ruleset** sur `main` : *Restrict
   deletions*, *Block force pushes*, et *Require status checks to pass*
   (la tâche `test`).
3. **Actions → General** : *Workflow permissions* = « Read repository contents
   and packages permissions ».
4. **Releases** : activer *Immutable releases* (une version publiée ne peut
   plus être modifiée).
5. Sur ton compte GitHub : **double authentification** (2FA) activée.
