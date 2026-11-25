// Mon PC : la page du téléphone, reliée à Mon Hub par le Wi-Fi de la maison.
// Toutes les adresses sont relatives : elles restent derrière le lien secret.
const $ = (id) => document.getElementById(id);
const api = (p) => `api/${p}`;

// ------------------------------------------------------------ Onglets
let tabNow = 'nexo';
function go(tab) {
  tabNow = tab;
  for (const s of document.querySelectorAll('section')) s.classList.toggle('on', s.dataset.tab === tab);
  for (const b of document.querySelectorAll('nav button')) b.classList.toggle('on', b.dataset.go === tab);
  try { localStorage.setItem('onglet', tab); } catch {}
  if (tab === 'texte' || tab === 'recevoir') refresh();
  if (tab === 'ecran') screenLoop();
  if (tab === 'telecommande') loadApps();
}
for (const b of document.querySelectorAll('nav button')) b.onclick = () => go(b.dataset.go);
// Après tout le reste (l'onglet Écran a besoin de ce qui est plus bas).
setTimeout(() => { try { const t = localStorage.getItem('onglet'); if (t) go(t); } catch {} }, 0);

let toastTimer = null;
function toast(text, ms = 2500) {
  const t = $('toast');
  t.textContent = text;
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (t.hidden = true), ms);
}

const size = (n) => (n < 1e6 ? `${Math.max(1, Math.round(n / 1e3))} Ko` : n < 1e9 ? `${(n / 1e6).toFixed(1).replace('.', ',')} Mo` : `${(n / 1e9).toFixed(2).replace('.', ',')} Go`);

// ------------------------------------------------------------ État du PC
let online = false;
async function refresh() {
  try {
    const st = await (await fetch(api('etat'), { cache: 'no-store' })).json();
    online = true;
    $('dot').className = 'dot ok';
    $('pc').textContent = st.pc || 'Mon PC';
    const clip = $('pc-clip');
    if (document.activeElement !== clip) clip.value = st.presse_papier || '';
    const list = $('files');
    list.replaceChildren(...(st.fichiers || []).map((f) => {
      const li = document.createElement('li');
      const name = document.createElement('span');
      name.className = 'name';
      name.textContent = f.nom;
      const s = document.createElement('span');
      s.className = 'size';
      s.textContent = size(f.taille);
      const a = document.createElement('a');
      a.href = api(`fichier/${encodeURIComponent(f.id)}`);
      a.setAttribute('download', f.nom);
      a.textContent = 'Télécharger';
      li.append(name, s, a);
      return li;
    }));
    if (!list.children.length) {
      const li = document.createElement('li');
      li.innerHTML = '<span class="sub">Rien pour l\'instant.</span>';
      list.append(li);
    }
    for (const b of document.querySelectorAll('[data-cmd]')) b.disabled = !st.telecommande;
    // Ce que ce PC sait faire (l'écran et Nexo : Windows avec Mon Hub ouvert).
    document.querySelector('[data-go="ecran"]').hidden = !st.ecran;
    document.querySelector('[data-go="nexo"]').hidden = !st.nexo;
  } catch {
    online = false;
    $('dot').className = 'dot ko';
    $('pc').textContent = 'PC injoignable (Mon Hub ouvert ? même Wi-Fi ?)';
  }
}
refresh();
setInterval(() => { if (!document.hidden) refresh(); }, 4000);
document.addEventListener('visibilitychange', () => { if (!document.hidden) refresh(); });

// ------------------------------------------------------------ Envoyer
const queue = [];
let sending = false;
$('pick').onchange = (e) => {
  for (const f of e.target.files) queue.push(f);
  e.target.value = '';
  pump();
};

function row(file) {
  const li = document.createElement('li');
  li.innerHTML = '<div style="flex:1;min-width:0"><div class="name"></div><div class="bar"><div></div></div></div><span class="size"></span>';
  li.querySelector('.name').textContent = file.name;
  li.querySelector('.size').textContent = size(file.size);
  $('sent').prepend(li);
  return li;
}

async function pump() {
  if (sending) return;
  sending = true;
  while (queue.length) {
    const f = queue.shift();
    const li = row(f);
    const bar = li.querySelector('.bar > div');
    const ok = await new Promise((resolve) => {
      const x = new XMLHttpRequest();
      x.open('POST', api('envoyer'));
      x.setRequestHeader('x-nom', encodeURIComponent(f.name));
      x.upload.onprogress = (ev) => { if (ev.lengthComputable) bar.style.width = `${(ev.loaded / ev.total) * 100}%`; };
      x.onload = () => resolve(x.status === 200);
      x.onerror = () => resolve(false);
      x.send(f);
    });
    bar.style.width = '100%';
    li.querySelector('.size').textContent = ok ? '✅' : '❌';
    if (!ok) toast(`« ${f.name} » n'est pas passé. Le PC est-il allumé, Mon Hub ouvert ?`, 4000);
  }
  sending = false;
  toast('Envoyé sur le PC ✅');
}

// ------------------------------------------------------------ Texte
$('btn-refresh').onclick = refresh;
$('btn-copy').onclick = async () => {
  const t = $('pc-clip');
  try {
    if (navigator.clipboard?.writeText) {
      await navigator.clipboard.writeText(t.value);
    } else {
      t.removeAttribute('readonly');
      t.focus();
      t.setSelectionRange(0, t.value.length);
      document.execCommand('copy');
      t.setAttribute('readonly', '');
      t.blur();
    }
    toast('Copié sur le téléphone 📋');
  } catch {
    toast('Sélectionne le texte et copie-le à la main.');
  }
};
$('btn-send-text').onclick = async () => {
  const text = $('my-text').value;
  if (!text.trim()) return toast('Écris ou colle un texte d\'abord.');
  try {
    const r = await fetch(api('texte'), { method: 'POST', body: text });
    if (!r.ok) throw new Error();
    $('my-text').value = '';
    toast('Dans le presse-papier du PC ✅');
  } catch {
    toast('Pas envoyé : le PC est-il joignable ?');
  }
};

// ------------------------------------------------------------ Télécommande
async function cmd(action, extra = {}) {
  try {
    const r = await (await fetch(api('commande'), { method: 'POST', body: JSON.stringify({ action, ...extra }), keepalive: true })).json();
    const quiet = ['souris', 'defiler', 'taper', 'touche', 'clic_ecran'].includes(action);
    if (r.message && r.message !== 'OK' && (!quiet || !r.ok)) toast(r.message);
  } catch {
    if (action !== 'souris') toast('Le PC ne répond pas.');
  }
}
for (const b of document.querySelectorAll('[data-cmd]')) {
  b.onclick = () => {
    if (b.dataset.confirm && !confirm(b.dataset.confirm)) return;
    if (navigator.vibrate) navigator.vibrate(15);
    cmd(b.dataset.cmd);
  };
}

// Pavé tactile : on regroupe les petits mouvements (un envoi toutes les 40 ms).
const pad = $('pad');
let acc = { dx: 0, dy: 0, sy: 0 };
let flushing = false;
let touchStart = null;
let last = null;
async function flush() {
  if (flushing) return;
  flushing = true;
  while (Math.abs(acc.dx) >= 1 || Math.abs(acc.dy) >= 1 || Math.abs(acc.sy) >= 1) {
    const dx = Math.round(acc.dx);
    const dy = Math.round(acc.dy);
    const sy = Math.trunc(acc.sy);
    acc.dx -= dx;
    acc.dy -= dy;
    acc.sy -= sy;
    if (sy) await cmd('defiler', { n: sy });
    if (dx || dy) await cmd('souris', { dx, dy });
    await new Promise((r) => setTimeout(r, 40));
  }
  flushing = false;
}
pad.addEventListener('touchstart', (e) => {
  e.preventDefault();
  const t = e.touches[0];
  touchStart = { x: t.clientX, y: t.clientY, at: Date.now(), moved: 0, fingers: e.touches.length };
  last = { x: t.clientX, y: t.clientY };
}, { passive: false });
pad.addEventListener('touchmove', (e) => {
  e.preventDefault();
  const t = e.touches[0];
  if (!last) return;
  const dx = t.clientX - last.x;
  const dy = t.clientY - last.y;
  last = { x: t.clientX, y: t.clientY };
  touchStart.moved += Math.abs(dx) + Math.abs(dy);
  touchStart.fingers = Math.max(touchStart.fingers, e.touches.length);
  if (e.touches.length >= 2) {
    acc.sy += -dy / 18;
  } else {
    const speed = Math.min(3, 1.4 + Math.hypot(dx, dy) / 12);
    acc.dx += dx * speed;
    acc.dy += dy * speed;
  }
  flush();
}, { passive: false });
pad.addEventListener('touchend', (e) => {
  e.preventDefault();
  if (touchStart && e.touches.length === 0) {
    if (touchStart.moved < 8 && Date.now() - touchStart.at < 300) cmd(touchStart.fingers >= 2 ? 'clic_droit' : 'clic');
    touchStart = null;
    last = null;
  }
}, { passive: false });
// À la souris (essai depuis un ordinateur).
pad.addEventListener('mousedown', (e) => { last = { x: e.clientX, y: e.clientY }; });
window.addEventListener('mousemove', (e) => {
  if (!last || !(e.buttons & 1)) return;
  acc.dx += (e.clientX - last.x) * 1.5;
  acc.dy += (e.clientY - last.y) * 1.5;
  last = { x: e.clientX, y: e.clientY };
  flush();
});
window.addEventListener('mouseup', () => (last = null));

// ------------------------------------------------- Écran d'accueil (iPhone)
const ios = /iphone|ipad|ipod/i.test(navigator.userAgent);
if (ios && !navigator.standalone) $('btn-home').hidden = false;
$('btn-home').onclick = () => ($('home-help').hidden = false);
$('btn-home-ok').onclick = () => ($('home-help').hidden = true);


// ------------------------------------------------------------ Nexo
const chat = $('chat');
function bubble(text, who) {
  const d = document.createElement('div');
  d.className = `msg ${who}`;
  d.textContent = text;
  chat.append(d);
  chat.scrollTop = chat.scrollHeight;
  return d;
}
try { $('speak-reply').checked = localStorage.getItem('lire') === '1'; } catch {}
$('speak-reply').onchange = (e) => { try { localStorage.setItem('lire', e.target.checked ? '1' : '0'); } catch {} };

function say(text) {
  if (!$('speak-reply').checked || !window.speechSynthesis) return;
  const u = new SpeechSynthesisUtterance(text.replace(/[\u{1F300}-\u{1FAFF}\u2600-\u27BF]/gu, ''));
  u.lang = 'fr-FR';
  const v = speechSynthesis.getVoices().find((x) => x.lang && x.lang.startsWith('fr'));
  if (v) u.voice = v;
  speechSynthesis.cancel();
  speechSynthesis.speak(u);
}

let asking = false;
async function askNexo(q) {
  q = (q || '').trim();
  if (!q || asking) return;
  asking = true;
  bubble(q, 'me');
  const wait = bubble('Nexo réfléchit…', 'nexo wait');
  try {
    const r = await (await fetch(api('nexo'), { method: 'POST', body: JSON.stringify({ texte: q }) })).json();
    wait.className = 'msg nexo';
    wait.textContent = r.reponse || 'C\'est fait.';
    say(wait.textContent);
  } catch {
    wait.className = 'msg nexo';
    wait.textContent = 'Le PC ne répond pas (Mon Hub ouvert ? même Wi-Fi ?).';
  }
  chat.scrollTop = chat.scrollHeight;
  asking = false;
}
$('btn-ask').onclick = () => { const t = $('ask-text'); askNexo(t.value); t.value = ''; };
$('ask-text').addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); $('btn-ask').click(); } });
for (const b of document.querySelectorAll('[data-ask]')) b.onclick = () => askNexo(b.dataset.ask);

// La dictée du téléphone (Chrome sur Android, Safari sur iPhone).
const Rec = window.SpeechRecognition || window.webkitSpeechRecognition;
let rec = null;
if (!Rec) {
  $('btn-mic').onclick = () => toast('Ton navigateur n\'a pas la dictée : utilise le micro du clavier 🎙️', 3500);
} else {
  $('btn-mic').onclick = () => {
    if (rec) { rec.stop(); return; }
    rec = new Rec();
    rec.lang = 'fr-FR';
    rec.interimResults = true;
    rec.maxAlternatives = 1;
    let text = '';
    $('btn-mic').classList.add('on');
    rec.onresult = (e) => {
      text = Array.from(e.results).map((r) => r[0].transcript).join(' ');
      $('ask-text').value = text;
    };
    rec.onerror = (e) => { if (e.error !== 'aborted' && e.error !== 'no-speech') toast('Micro : ' + e.error); };
    rec.onend = () => {
      $('btn-mic').classList.remove('on');
      rec = null;
      if (text.trim()) { $('ask-text').value = ''; askNexo(text); }
    };
    if (navigator.vibrate) navigator.vibrate(20);
    rec.start();
  };
}

// ------------------------------------------------------------ Écran du PC
const screen = $('screen');
let screenOn = false;
let sharp = true;
try { sharp = localStorage.getItem('net') !== '0'; } catch {}
$('btn-quality').textContent = sharp ? 'Net' : 'Rapide';
$('btn-quality').onclick = () => {
  sharp = !sharp;
  $('btn-quality').textContent = sharp ? 'Net' : 'Rapide';
  try { localStorage.setItem('net', sharp ? '1' : '0'); } catch {}
};
async function screenLoop() {
  if (screenOn) return;
  screenOn = true;
  let lastUrl = null;
  while (tabNow === 'ecran' && !document.hidden) {
    const t0 = Date.now();
    try {
      const w = Math.round(Math.min(1600, (screen.clientWidth || 360) * (window.devicePixelRatio || 1) * (sharp ? 1 : 0.6)));
      const r = await fetch(api(`ecran?l=${Math.max(320, w)}`), { cache: 'no-store' });
      if (!r.ok) throw new Error();
      const url = URL.createObjectURL(await r.blob());
      await new Promise((ok) => { screen.onload = ok; screen.onerror = ok; screen.src = url; });
      if (lastUrl) URL.revokeObjectURL(lastUrl);
      lastUrl = url;
      $('screen-hint').hidden = true;
    } catch {
      $('screen-hint').hidden = false;
      $('screen-hint').textContent = 'Écran indisponible (Mon Hub ouvert sur le PC ?)';
      await new Promise((ok) => setTimeout(ok, 1500));
    }
    await new Promise((ok) => setTimeout(ok, Math.max(60, 250 - (Date.now() - t0))));
  }
  screenOn = false;
}
document.addEventListener('visibilitychange', () => { if (!document.hidden && tabNow === 'ecran') screenLoop(); });

// Toucher = clic ; appui long = clic droit ; deux touches rapides = double-clic ; 2 doigts = défiler.
let press = null;
let lastTap = 0;
function point(t) {
  const r = screen.getBoundingClientRect();
  return { x: (t.clientX - r.left) / r.width, y: (t.clientY - r.top) / r.height };
}
screen.addEventListener('touchstart', (e) => {
  e.preventDefault();
  const t = e.touches[0];
  press = { ...point(t), cx: t.clientX, cy: t.clientY, y0: t.clientY, at: Date.now(), moved: 0, fingers: e.touches.length };
  press.timer = setTimeout(() => {
    if (press && press.moved < 10 && press.fingers === 1) {
      if (navigator.vibrate) navigator.vibrate(30);
      cmd('clic_ecran', { x: press.x, y: press.y, droit: true });
      press.done = true;
    }
  }, 550);
}, { passive: false });
screen.addEventListener('touchmove', (e) => {
  e.preventDefault();
  if (!press) return;
  const t = e.touches[0];
  press.moved += Math.abs(t.clientX - press.cx) + Math.abs(t.clientY - press.cy);
  press.fingers = Math.max(press.fingers, e.touches.length);
  if (e.touches.length >= 2) {
    const n = Math.trunc((press.y0 - t.clientY) / 24);
    if (n) { cmd('defiler', { n }); press.y0 = t.clientY; }
  }
  press.cx = t.clientX;
  press.cy = t.clientY;
}, { passive: false });
screen.addEventListener('touchend', (e) => {
  e.preventDefault();
  if (!press || e.touches.length) return;
  clearTimeout(press.timer);
  if (!press.done && press.moved < 10 && press.fingers === 1) {
    const now = Date.now();
    const double = now - lastTap < 320;
    lastTap = double ? 0 : now;
    if (navigator.vibrate) navigator.vibrate(12);
    cmd('clic_ecran', { x: press.x, y: press.y, double });
  }
  press = null;
}, { passive: false });
screen.addEventListener('click', (e) => {
  if (e.pointerType === 'touch' || !e.isTrusted || e.detail === 0) return;
  const p = point(e);
  cmd('clic_ecran', { x: p.x, y: p.y });
});

// Le clavier du téléphone tape directement sur le PC.
const kbd = $('live-kbd');
$('btn-kbd').onclick = () => { kbd.value = ''; kbd.focus(); toast('Tape : ça s\'écrit sur le PC ⌨️'); };
kbd.addEventListener('input', (e) => {
  if (e.inputType === 'deleteContentBackward') cmd('touche', { touche: 'backspace' });
  else if (e.data) cmd('taper', { texte: e.data });
  kbd.value = '';
});
kbd.addEventListener('keydown', (e) => {
  if (e.key === 'Enter') { e.preventDefault(); cmd('touche', { touche: 'enter' }); }
  else if (e.key === 'Backspace' && !kbd.value) { e.preventDefault(); cmd('touche', { touche: 'backspace' }); }
});

// Les fenêtres ouvertes.
$('btn-wins').onclick = async () => {
  const ul = $('wins');
  if (!ul.hidden) { ul.hidden = true; return; }
  try {
    const list = await (await fetch(api('fenetres'), { cache: 'no-store' })).json();
    ul.replaceChildren(...list.map((w) => {
      const li = document.createElement('li');
      const n = document.createElement('span');
      n.className = 'name';
      n.textContent = w.titre;
      const a = document.createElement('button');
      a.className = 'small';
      a.textContent = 'Afficher';
      a.onclick = () => { cmd('fenetre', { id: w.id, faire: 'activer' }); ul.hidden = true; };
      li.append(n, a);
      return li;
    }));
    ul.hidden = false;
  } catch { toast('Le PC ne répond pas.'); }
};

// ------------------------------------------------------------ Taper et applis
$('btn-type').onclick = () => {
  const t = $('type-text');
  if (!t.value) return toast('Écris le texte à taper.');
  cmd('taper', { texte: t.value });
  t.value = '';
};
$('type-text').addEventListener('keydown', (e) => {
  if (e.key === 'Enter') { e.preventDefault(); const t = $('type-text'); if (t.value) { cmd('taper', { texte: t.value, entree: true }); t.value = ''; } }
});
for (const b of document.querySelectorAll('[data-key]')) b.onclick = () => cmd('touche', { touche: b.dataset.key });

let appsTimer = null;
let appsLoaded = false;
async function loadApps(q = '') {
  if (!q && appsLoaded) return;
  try {
    const list = await (await fetch(api(`applis?q=${encodeURIComponent(q)}`), { cache: 'no-store' })).json();
    appsLoaded = !q;
    $('apps').replaceChildren(...list.slice(0, 24).map((a) => {
      const b = document.createElement('button');
      const i = document.createElement('b');
      i.textContent = a.ini;
      const n = document.createElement('span');
      n.textContent = a.nom;
      b.append(i, n);
      b.onclick = () => { if (navigator.vibrate) navigator.vibrate(15); cmd('lancer', { id: a.id }); };
      return b;
    }));
  } catch {}
}
$('app-search').addEventListener('input', (e) => {
  clearTimeout(appsTimer);
  appsTimer = setTimeout(() => loadApps(e.target.value.trim()), 250);
});
