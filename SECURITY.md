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
