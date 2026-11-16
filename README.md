# Mon Hub

Une vraie application (pas un site) qui regroupe au même endroit : emploi du
temps, École Directe, mails, Discord, Instagram, comptes Roblox, livres lus et
raccourcis Google Drive. Chaque bloc est un **module** qu'on peut masquer,
réordonner, retirer ou remplacer.

![Capture](docs/capture.png)

## Sur quels appareils ?

Écrite en **Flutter** : un seul code pour **Windows, Android, iPhone/iPad,
Mac et Linux**. Chaque appareil reçoit une vraie appli native installée.

| Appareil | Comment l'obtenir |
|---|---|
| Windows | Dossier `MonHub-Windows` produit par GitHub Actions → lancer `hub.exe` |
| Android | `app-release.apk` produit par GitHub Actions → l'installer sur le téléphone |
| Mac / Linux | Idem, artefacts `MonHub-macOS` / `MonHub-Linux` |
| iPhone | Nécessite un Mac avec Xcode (`flutter run` sur l'iPhone branché) ou un compte développeur Apple (99 €/an) pour TestFlight |

## Ce que chaque module sait faire (honnêtement)

| Module | Accès | Ce qui marche |
|---|---|---|
| **Agenda** | ✅ Officiel (iCal) | Affiche Google Agenda (ou tout agenda .ics) sur 14 jours, récurrences comprises. Lien : Google Agenda → Paramètres → ton agenda → « Adresse secrète au format iCal ». |
| **École Directe** | ⚠️ Non officiel | Connexion + question de sécurité + emploi du temps de la semaine. École Directe n'a pas d'API publique : on imite leur site, ça peut casser après une de leurs mises à jour (correctif dans `ed_client.dart`). |
| **Mails** | ✅ Standard (IMAP) | Derniers mails et non lus, plusieurs boîtes. Gmail : créer un **mot de passe d'application** (myaccount.google.com/apppasswords, validation en 2 étapes requise). Outlook/Hotmail : Microsoft a coupé les mots de passe en IMAP, il faudra une connexion OAuth (évolution prévue). |
| **Discord** | ✅ Officiel (limité) | Raccourci vers tes MP + nombre de membres en ligne de tes serveurs (si le widget du serveur est activé). Lire tes MP depuis une autre appli est **interdit** par Discord (risque de ban), donc pas fait. |
| **Instagram** | ❌ Pas d'API | Instagram a fermé son API pour les comptes perso (déc. 2024). Le module est donc une liste de raccourcis qui ouvrent l'appli Instagram (profils, messages). |
| **Roblox** | ⚠️ Semi-public | Plusieurs comptes : avatar, nombre d'amis, statut (en ligne / en jeu). Utilise les API publiques du site Roblox, sans mot de passe. |
| **Mes livres** | ✅ Local | Liste de tous tes livres lus, note, date, avis, recherche de couverture via Open Library. |
| **Google Drive** | Raccourcis | Liens vers tes documents Drive (emploi du temps PDF, etc.). |

Mots de passe et jetons sont stockés dans le coffre sécurisé du système
(Gestionnaire d'identification Windows, Keystore Android, Trousseau Apple).

## Ajouter, retirer ou remplacer un module

Dans l'appli : bouton ⊞ en haut à droite → cocher/décocher, glisser pour
réordonner.

Dans le code, tout passe par **un seul fichier** :
[`lib/core/module_registry.dart`](lib/core/module_registry.dart).

1. Créer `lib/modules/mon_module/mon_module.dart` avec une classe qui étend
   `HubModule` (voir [`lib/core/hub_module.dart`](lib/core/hub_module.dart)) :
   `id`, `name`, `icon`, `color`, `buildSummary()` (la tuile) et
   `buildPage()` (la page complète). `store` donne un stockage privé au module.
2. L'ajouter à la liste dans `module_registry.dart`.

Pour un simple module de raccourcis (TikTok, YouTube, Pronote…), pas besoin
de code : ajouter une ligne `LinksModule(...)` dans cette même liste.

## Développer

```bash
flutter pub get
flutter run -d windows   # ou: android, macos, linux, chrome…
flutter test
```

Structure :

```
lib/
  main.dart                 démarrage
  core/                     contrat de module, stockage, registre, contrôleur
  ui/                       tableau de bord, page Modules, widgets communs
  modules/<nom>/            un dossier par module, indépendant des autres
```
