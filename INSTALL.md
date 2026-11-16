# Installer Mon Hub

Liens de téléchargement (toujours la dernière version) :

- **PC Windows** : https://github.com/Shideyx/mon-hub/releases/latest/download/MonHub-Windows.zip
- **Téléphone Android** : https://github.com/Shideyx/mon-hub/releases/latest/download/MonHub-Android.apk
- **iPhone** : https://github.com/Shideyx/mon-hub/releases/latest/download/MonHub-iOS.ipa (à installer depuis un PC, voir plus bas)
- **Extension Claude (PC)** : https://github.com/Shideyx/mon-hub/releases/latest/download/MonHub-Claude.mcpb

## 1. Sur le PC (Windows 10 ou 11)

1. Télécharge **MonHub-Windows.zip**.
2. Clic droit sur le fichier → **Extraire tout…** → choisis par exemple `Documents\Mon Hub` → **Extraire**.
3. Dans le dossier, double-clique sur **hub.exe**.
4. Si Windows affiche « Windows a protégé votre ordinateur » : clique sur **Informations complémentaires** puis **Exécuter quand même** (normal pour une appli qui n'est pas sur le Microsoft Store).
5. C'est tout : au premier lancement, Mon Hub crée tout seul ses raccourcis **sur le Bureau** et **dans le menu Démarrer** (ils sont réparés automatiquement si tu déplaces le dossier ou installes une nouvelle version ailleurs). Pour l'épingler : clic droit sur le raccourci → **Épingler à la barre des tâches**. Option : *Réglages → Lancer Mon Hub au démarrage de Windows*.
6. Si la page de connexion Instagram/Discord reste blanche : installe **Microsoft Edge WebView2** (déjà présent sur la plupart des PC) depuis https://go.microsoft.com/fwlink/p/?LinkId=2124703

## 2. Sur le téléphone Android

1. Sur le téléphone, ouvre le lien **MonHub-Android.apk** et télécharge-le.
2. Ouvre le fichier téléchargé (notification ou appli *Fichiers* → *Téléchargements*).
3. Android demande d'autoriser l'installation depuis cette source : appuie sur **Paramètres** → active **Autoriser cette source** → reviens en arrière → **Installer**.
4. Si Play Protect affiche un avertissement : **Plus de détails** → **Installer quand même**.
5. Au premier lancement, **autorise les notifications** pour recevoir les alertes.

## 2 bis. Sur iPhone (iPhone 12 et plus récents, iOS 15+)

Apple n'autorise que l'App Store, sauf pour les applis « installées par le développeur ». On passe donc par **Sideloadly** (gratuit) depuis le PC, avec ton identifiant Apple :

1. Sur le PC, installe **iTunes** (version du site d'Apple, pas du Microsoft Store) puis **Sideloadly** : https://sideloadly.io
2. Télécharge **MonHub-iOS.ipa**.
3. Branche l'iPhone en USB, déverrouille-le et appuie sur **Faire confiance**.
4. Ouvre Sideloadly, glisse le fichier `.ipa` dedans, tape ton **identifiant Apple** et clique sur **Start** (mot de passe Apple demandé : c'est Apple qui le vérifie).
5. Sur l'iPhone : **Réglages → Général → VPN et gestion de l'appareil** → ton identifiant → **Faire confiance**. Puis **Réglages → Confidentialité et sécurité → Mode développeur** → activer (l'iPhone redémarre).
6. Ouvre Mon Hub et autorise les notifications.

> Avec un identifiant Apple gratuit, Apple limite l'installation à **7 jours** : il suffit de refaire l'étape 4 (Sideloadly peut le faire tout seul quand l'iPhone est sur le même Wi-Fi). Pour éviter ça, il faut le compte développeur Apple (99 €/an) ou une publication sur l'App Store.

## 3. Créer ton compte Mon Hub

Au premier lancement : **identifiant + mot de passe** → **Créer mon compte**. Chaque personne qui utilise l'appli a son propre compte, avec ses propres connexions. Le bouton 🌙 / ☀️ (en haut) passe en **mode sombre** ou **clair** ; *Réglages → Apparence* propose aussi « Auto ».

## 3 bis. Connecter tes comptes (une seule fois, sur le PC)

Pour Instagram, Discord et Claude, c'est la vraie page de connexion du service qui s'ouvre dans l'appli : tu tapes ton identifiant et ton mot de passe, c'est tout.


| Service | Comment |
|---|---|
| **Instagram** | Carte Instagram → **Connecter** → connecte-toi sur la page Instagram qui s'ouvre. Elle se ferme toute seule. |
| **Discord** | Carte Discord → **Connecter** → **Continuer** → connecte-toi sur la page Discord. Elle se ferme toute seule. |
| **Mails (Gmail)** | Carte Mails → **Ajouter** → **Se connecter avec Google** → choisis ton compte → **Autoriser**. *(Si Google affiche « appli non validée » : Paramètres avancés → Accéder à Mon Hub.)* Autres boîtes (Orange, Free…) : adresse + mot de passe. |
| **École Directe** | Carte École Directe → **Se connecter** → identifiant + mot de passe. Réponds à la question de sécurité la première fois. |
| **Agenda** | Les cours École Directe y apparaissent tout seuls. Bouton 🔗 en haut de l'Agenda → **Se connecter avec Google** → Autoriser : tes évènements Google s'affichent, et tu peux en ajouter directement dans Google Agenda. Bouton **+ Ajouter** (ou clic sur un créneau vide) pour tes évènements. |
| **Roblox** | Carte Roblox → **Ajouter un compte** → ton pseudo (pas de mot de passe). |
| **Livres** | Bibliothèque → **Ajouter un livre** → cherche le titre. |

| **Claude** | Carte Claude → **Ouvrir Claude** → connecte-toi comme sur claude.ai (si « Continuer avec Google » refuse dans l'appli, choisis « Continuer avec l'e-mail »). |

## 3 ter. Clicky, ton compagnon à côté du curseur

1. Carte **Claude** → **Configurer Clicky** → choisis son cerveau :
   - **Claude Pro** (conseillé si tu as un abonnement Claude Pro / Max) : Clicky utilise ton abonnement via **Claude Code**, l'outil officiel d'Anthropic. Dans les réglages : **Installer Claude Code** (une fenêtre s'ouvre et l'installe), puis **Se connecter** (la page officielle de Claude s'ouvre dans ton navigateur), puis ↻. Mon Hub ne voit jamais ta connexion ; les questions comptent dans les limites de ton abonnement.
   - **Clé API** : crée une clé sur https://console.anthropic.com/settings/keys (payée à l'usage, quelques centimes par question) et colle-la.
   - **Local gratuit (Ollama)** : sans clé ni compte, rien ne sort du PC. Installe https://ollama.com/download puis, dans un terminal : `ollama pull qwen2.5vl`. Il faut un PC assez puissant.
2. **Maintiens Ctrl + Alt et parle**, relâche pour envoyer (appui court = écrire). Sur téléphone : touche la bulle bleue.
3. Sur Windows, **Clicky partout** (activé par défaut) : Clicky suit ta souris au-dessus de toutes tes applis et voit tous tes écrans, même Mon Hub réduit.
4. Commence par **« Agent, … »** pour une tâche de fond (ex. « Agent, résume mes devoirs de la semaine ») : Clicky te prévient quand c'est fini.

Le micro de Windows doit comprendre le français : *Paramètres → Heure et langue → Voix* (installe le pack français si besoin).

## 3 quater. Laisser l'appli Claude agir dans Mon Hub (PC)

1. Installe l'appli **Claude pour Windows** : https://claude.ai/download et connecte-toi.
2. Télécharge **MonHub-Claude.mcpb** et double-clique dessus : Claude s'ouvre → **Installer**.
3. Laisse Mon Hub ouvert, puis demande à Claude : « Qu'est-ce que j'ai demain ? », « Ajoute foot mercredi 14h », « Réponds à Léo sur Discord que j'arrive »… Claude demande ta permission avant chaque action.

## 4. Copier la configuration sur le téléphone

1. Sur le PC : **Réglages → Exporter ma configuration** → enregistre `mon-hub-config.json`.
2. Envoie ce fichier sur ton téléphone (Google Drive, câble USB…).
3. Sur le téléphone : **Réglages → Importer une configuration** → choisis le fichier → redémarre l'appli.
4. **Supprime le fichier** de Drive et du téléphone ensuite : il contient tes mots de passe.

## 5. Mettre à jour

Re-télécharge simplement le fichier depuis les mêmes liens. Sur PC, remplace l'ancien dossier (tes comptes sont conservés, les raccourcis se mettent à jour tout seuls). Sur Android, installe le nouvel APK par-dessus.

## En cas de problème

- **« Session expirée »** sur Instagram ou Discord : appuie sur **Déconnecter** puis **Connecter**.
- **Instagram : la page de connexion ne se ferme pas** : une fois connecté sur la page, appuie sur **J'ai fini** en haut à droite.
- **Instagram demande une vérification** : ouvre l'appli Instagram ou instagram.com, confirme « C'était moi », puis reconnecte-toi dans Mon Hub.
- **École Directe** : le message d'erreur affiché dit maintenant ce qui bloque (mot de passe, question de sécurité, maintenance…).
- **Mails : erreur de connexion** : vérifie que tu as utilisé le mot de passe d'application, pas ton mot de passe Google.
- **Pas de notifications sur Android** : Paramètres du téléphone → Applis → Mon Hub → Notifications → activer, et Batterie → *Sans restriction*.
- **École Directe ne marche plus** : leur site a sans doute changé, préviens-moi.
