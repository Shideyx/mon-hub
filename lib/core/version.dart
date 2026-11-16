/// Numéro de la version installée (ex. « v1.19 »), donné par GitHub au
/// moment de la compilation. Affiché dans les Réglages et sur la page de
/// connexion pour savoir d'un coup d'œil si on a bien la dernière version.
const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'développement');
