# Installer Mon Hub

Liens de téléchargement (toujours la dernière version) :

- **PC Windows** : https://github.com/Shideyx/mon-hub/releases/latest/download/MonHub-Windows.zip
- **Téléphone Android** : https://github.com/Shideyx/mon-hub/releases/latest/download/MonHub-Android.apk

## 1. Sur le PC (Windows 10 ou 11)

1. Télécharge **MonHub-Windows.zip**.
2. Clic droit sur le fichier → **Extraire tout…** → choisis par exemple `Documents\Mon Hub` → **Extraire**.
3. Dans le dossier, double-clique sur **hub.exe**.
4. Si Windows affiche « Windows a protégé votre ordinateur » : clique sur **Informations complémentaires** puis **Exécuter quand même** (normal pour une appli qui n'est pas sur le Microsoft Store).
5. Pour l'avoir sous la main : clic droit sur `hub.exe` → **Épingler à la barre des tâches**.
6. Si la page de connexion Instagram/Discord reste blanche : installe **Microsoft Edge WebView2** (déjà présent sur la plupart des PC) depuis https://go.microsoft.com/fwlink/p/?LinkId=2124703

## 2. Sur le téléphone Android

1. Sur le téléphone, ouvre le lien **MonHub-Android.apk** et télécharge-le.
2. Ouvre le fichier téléchargé (notification ou appli *Fichiers* → *Téléchargements*).
3. Android demande d'autoriser l'installation depuis cette source : appuie sur **Paramètres** → active **Autoriser cette source** → reviens en arrière → **Installer**.
4. Si Play Protect affiche un avertissement : **Plus de détails** → **Installer quand même**.
5. Au premier lancement, **autorise les notifications** pour recevoir les alertes.

> iPhone : pas encore possible sans Mac (Apple impose Xcode ou un compte développeur à 99 €/an).

## 3. Connecter tes comptes (une seule fois, sur le PC)

| Service | Comment |
|---|---|
| **Instagram** | Carte Instagram → **Connecter** → connecte-toi sur la page Instagram qui s'ouvre. Elle se ferme toute seule. |
| **Discord** | Carte Discord → **Connecter** → **Continuer** → connecte-toi sur la page Discord. Elle se ferme toute seule. |
| **Mails (Gmail)** | Carte Mails → **Ajouter** → **Ouvrir la page Google** → crée un mot de passe d'application nommé « Mon Hub » → copie les 16 lettres → reviens et colle-les avec ton adresse. *(La validation en 2 étapes doit être activée sur ton compte Google.)* |
| **École Directe** | Carte École Directe → **Se connecter** → identifiant + mot de passe. Réponds à la question de sécurité la première fois. |
| **Agenda Google** | Sur ordinateur : Google Agenda → ⚙️ Paramètres → ton agenda → *Intégrer l'agenda* → copie l'**Adresse secrète au format iCal** → colle-la dans la carte Agenda. |
| **Roblox** | Carte Roblox → **Ajouter un compte** → ton pseudo (pas de mot de passe). |
| **Livres** | Bibliothèque → **Ajouter un livre** → cherche le titre. |

Puis **Réglages → Ton prénom** pour le message d'accueil.

## 4. Copier la configuration sur le téléphone

1. Sur le PC : **Réglages → Exporter ma configuration** → enregistre `mon-hub-config.json`.
2. Envoie ce fichier sur ton téléphone (Google Drive, câble USB…).
3. Sur le téléphone : **Réglages → Importer une configuration** → choisis le fichier → redémarre l'appli.
4. **Supprime le fichier** de Drive et du téléphone ensuite : il contient tes mots de passe.

## 5. Mettre à jour

Re-télécharge simplement le fichier depuis les mêmes liens. Sur PC, remplace l'ancien dossier (tes comptes sont conservés). Sur Android, installe le nouvel APK par-dessus.

## En cas de problème

- **« Session expirée »** sur Instagram ou Discord : appuie sur **Déconnecter** puis **Connecter**.
- **Mails : erreur de connexion** : vérifie que tu as utilisé le mot de passe d'application, pas ton mot de passe Google.
- **Pas de notifications sur Android** : Paramètres du téléphone → Applis → Mon Hub → Notifications → activer, et Batterie → *Sans restriction*.
- **École Directe ne marche plus** : leur site a sans doute changé, préviens-moi.
