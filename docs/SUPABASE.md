# Mon Hub en ligne (Supabase) — le régler en 5 minutes

Mon Hub en ligne sert à deux choses :

1. **Même compte partout** : sur un autre PC, un Android ou un iPhone, tu tapes ton adresse mail et ton mot de passe
   sur la page de connexion (« Mon compte en ligne »), et tout ton Mon Hub revient (modules, réglages, connexions,
   historiques, révisions…).
2. **Espaces partagés** : des espaces avec tes amis, ta classe ou ton équipe (tableau de tâches + discussion en direct),
   des messages privés (@pseudo), et Clicky qui peut répondre dans les discussions.

Le serveur, c'est **ton** projet Supabase (gratuit). Mon Hub n'a toujours pas de serveur à lui.

## 1. Créer le projet (une fois)

1. Va sur [supabase.com](https://supabase.com/dashboard/new), crée un compte puis un **projet** (le nom que tu veux,
   région **Europe**, note le mot de passe de la base quelque part).
2. Dans Mon Hub : **Réglages → Compte en ligne et espaces → Compte en ligne → « Copier le script »**.
3. Dans ton projet Supabase : **SQL Editor → New query → colle → Run**. (Le script est aussi dans
   `supabase/schema.sql`. On peut le relancer sans risque.)
4. Conseillé : **Authentication → Sign In / Providers → Email** → décoche **« Confirm email »**. Sinon, il faut
   cliquer le lien reçu par mail à la création du compte.
5. **Project Settings → API** (ou le bouton **Connect**) : copie **Project URL** et la clé **anon public**, colle-les
   dans Mon Hub (Réglages → Compte en ligne) → **Enregistrer le serveur**.

## 2. Mettre ton compte en ligne

Réglages → Compte en ligne → ton adresse mail + **le mot de passe de ton compte Mon Hub** → **Mettre en ligne**.
Ensuite, sur un autre appareil : page de connexion → **« Mon compte en ligne (adresse mail) »**.

## 3. Inviter tes amis

* Ils doivent utiliser **le même serveur** : Réglages → Compte en ligne → **Copier le code du serveur**, envoie-leur
  le code « MONHUB-SERVEUR:… » ; eux : Réglages → Compte en ligne → « J'ai un code ».
* Dans un espace : **Inviter** → donne le code à 10 caractères ; eux : Espaces → **Rejoindre**.

## Pour que tout le monde ait le serveur sans rien régler (facultatif)

Dans GitHub → le dépôt → **Settings → Secrets and variables → Actions**, ajoute deux secrets :
`SUPABASE_URL` (Project URL) et `SUPABASE_ANON_KEY` (clé anon public). La prochaine version de Mon Hub les contiendra :
plus besoin de code serveur.

## Vie privée et sécurité

* Le serveur **ne reçoit jamais ton mot de passe** : seulement une empreinte (`Online.authPassword`).
* La copie de ton compte (`account_files`) est **chiffrée sur ton appareil** (AES-256-GCM, clé tirée de ton mot de
  passe) : le serveur ne peut pas la lire.
* Chaque table est protégée (**Row Level Security**) : on ne voit que les espaces dont on est membre, et seulement
  sa propre copie. On n'entre dans un espace qu'avec son code (ou en étant invité en privé).
* Ce que Clicky voit à l'écran, le temps d'écran, les guetteurs et la sauvegarde des travaux **restent sur le PC**.
* Les messages des autres sont lus par Clicky comme des **données**, jamais comme des ordres, et Clicky n'a aucun
  outil dans les discussions (il ne touche à rien sur ton PC).
