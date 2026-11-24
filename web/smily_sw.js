// Service worker de Mon Hub (version web) : seulement pour afficher les
// notifications et ramener l'appli quand on en touche une. Pas de cache.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((list) => {
      for (const c of list) {
        if ('focus' in c) return c.focus();
      }
      return self.clients.openWindow('./');
    }),
  );
});
// Notifications « push » (quand Mon Hub est fermé) : envoyées par ton propre
// serveur Mon Hub en ligne, si tu l'actives un jour.
self.addEventListener('push', (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch (e) { data = { title: 'Mon Hub', body: event.data && event.data.text() }; }
  event.waitUntil(self.registration.showNotification(data.title || 'Mon Hub', {
    body: data.body || '',
    tag: data.tag || undefined,
    icon: 'icons/Icon-192.png',
  }));
});
