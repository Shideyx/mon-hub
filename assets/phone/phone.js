// Mon PC : la page du téléphone, reliée à Mon Hub par le Wi-Fi de la maison.
// Toutes les adresses sont relatives : elles restent derrière le lien secret.
const $ = (id) => document.getElementById(id);
const api = (p) => `api/${p}`;

// ------------------------------------------------------------ Onglets
function go(tab) {
  for (const s of document.querySelectorAll('section')) s.classList.toggle('on', s.dataset.tab === tab);
  for (const b of document.querySelectorAll('nav button')) b.classList.toggle('on', b.dataset.go === tab);
  try { localStorage.setItem('onglet', tab); } catch {}
  if (tab === 'texte' || tab === 'recevoir') refresh();
}
for (const b of document.querySelectorAll('nav button')) b.onclick = () => go(b.dataset.go);
try { const t = localStorage.getItem('onglet'); if (t) go(t); } catch {}

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
    if (r.message && r.message !== 'OK' && action !== 'souris' && action !== 'defiler') toast(r.message);
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
