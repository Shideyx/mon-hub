// Mon Hub (version web) : les fonctions du téléphone utilisées par l'appli.
// Rien n'est envoyé ailleurs : tout reste dans le navigateur.
window.smily = {
  standalone: () => window.matchMedia('(display-mode: standalone)').matches || navigator.standalone === true,
  ios: () => /iPhone|iPad|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1),
  notifyState: () => ('Notification' in window) ? Notification.permission : 'absent',
  askNotify: async () => {
    if (!('Notification' in window)) return 'absent';
    try { return await Notification.requestPermission(); } catch (e) { return 'denied'; }
  },
  notify: async (title, body, tag) => {
    if (!('Notification' in window) || Notification.permission !== 'granted') return false;
    const options = { body: body, tag: tag || undefined, icon: 'icons/Icon-192.png', badge: 'icons/Icon-192.png' };
    try {
      if ('serviceWorker' in navigator) {
        const reg = await navigator.serviceWorker.ready;
        await reg.showNotification(title, options);
        return true;
      }
      new Notification(title, options);
      return true;
    } catch (e) {
      return false;
    }
  },
  share: async (text) => {
    if (!navigator.share) return false;
    try { await navigator.share({ text: text }); return true; } catch (e) { return false; }
  },
  vibrate: (ms) => (navigator.vibrate ? navigator.vibrate(ms) : false),
  // Fichier d'agenda (.ics) : l'iPhone propose « Ajouter au calendrier ».
  openFile: (name, mime, text) => {
    const url = URL.createObjectURL(new Blob([text], { type: mime }));
    if (window.smily.ios()) {
      window.location.href = url;
    } else {
      const a = document.createElement('a');
      a.href = url;
      a.download = name;
      document.body.appendChild(a);
      a.click();
      a.remove();
    }
    setTimeout(() => URL.revokeObjectURL(url), 60000);
  },
  hash: () => window.location.hash || '',
  clearHash: () => history.replaceState(null, '', window.location.pathname + window.location.search),
  hidden: () => document.visibilityState === 'hidden',
};

if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('smily_sw.js').catch(() => {});
  });
}
