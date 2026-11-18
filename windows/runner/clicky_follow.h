#ifndef RUNNER_CLICKY_FOLLOW_H_
#define RUNNER_CLICKY_FOLLOW_H_

#include <windows.h>

// Clicky partout suit la souris **directement dans Windows** : à chaque
// mouvement de la souris (« raw input », jusqu'à 1000 fois par seconde), la
// petite fenêtre de Clicky est déplacée tout de suite, sans attendre le code
// Dart ni une image de Flutter. Dart dit seulement quand suivre (et à quelle
// distance du curseur) ; pendant un vol vers une cible, c'est Dart qui place
// la fenêtre.
//
// Message envoyé par Dart (PostMessage) à la fenêtre de Clicky :
//   wParam = 1 : suivre la souris ; 0 : ne plus la suivre.
//   lParam = décalage (pixels physiques) : x dans les 16 bits du bas, y dans
//            les 16 bits du haut (avec signe).
constexpr UINT kClickyFollowMessage = WM_APP + 0x51;

namespace clicky_follow {

// Demande les mouvements de la souris, même quand Clicky n'est pas la
// fenêtre active.
void Attach(HWND window);

// À appeler pour chaque message de la fenêtre de Clicky. Renvoie true si le
// message est traité ici (il ne faut alors pas le passer à Windows).
bool Handle(HWND window, UINT message, WPARAM wparam, LPARAM lparam);

}  // namespace clicky_follow

#endif  // RUNNER_CLICKY_FOLLOW_H_
