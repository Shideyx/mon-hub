// La page des invités de la soirée : chercher, ajouter, voter.
const $ = (id) => document.getElementById(id);
const store = (k, v) => { try { if (v === undefined) return localStorage.getItem(k); localStorage.setItem(k, v); } catch {} return null; };

let guest = store('invite');
if (!guest) {
  guest = Array.from(crypto.getRandomValues(new Uint8Array(12)), (b) => b.toString(16).padStart(2, '0')).join('');
  store('invite', guest);
}
let name = store('prenom') || '';
const q = (p, extra = '') => `api/${p}?invite=${guest}${extra}`;

if (!name) $('who').hidden = false;
$('who-form').onsubmit = (e) => {
  e.preventDefault();
  name = $('name').value.trim().slice(0, 20);
  if (!name) return;
  store('prenom', name);
  $('who').hidden = true;
  $('q').focus();
};

let toastTimer;
function toast(t) {
  $('toast').textContent = t;
  $('toast').hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => ($('toast').hidden = true), 2500);
}

function item(song, button) {
  const li = document.createElement('li');
  const img = document.createElement('img');
  img.src = `https://i.ytimg.com/vi/${song.id}/mqdefault.jpg`;
  img.alt = '';
  img.loading = 'lazy';
  img.onerror = () => (img.style.visibility = 'hidden');
  const t = document.createElement('div');
  t.className = 't';
  const b = document.createElement('b');
  b.textContent = song.titre;
  const s = document.createElement('small');
  s.textContent = [song.chaine, song.duree, song.par ? `ajouté par ${song.par}` : ''].filter(Boolean).join(' · ');
  t.append(b, s);
  li.append(img, t, button);
  return li;
}

async function post(path, body) {
  const r = await fetch(q(path), { method: 'POST', body: JSON.stringify(body) });
  return r.json();
}

// ------------------------------------------------------------ Recherche
$('search').onsubmit = async (e) => {
  e.preventDefault();
  const text = $('q').value.trim();
  if (!text) return;
  const list = $('results');
  list.innerHTML = '<li class="empty">Je cherche…</li>';
  try {
    const r = await (await fetch(q('chercher', `&q=${encodeURIComponent(text)}`))).json();
    list.replaceChildren(...(r.resultats || []).map((v) => {
      const add = document.createElement('button');
      add.textContent = '+ Ajouter';
      add.onclick = async () => {
        add.disabled = true;
        const res = await post('ajouter', { id: v.id, titre: v.titre, chaine: v.chaine || '', duree: v.duree || '', nom: name });
        toast(res.message || 'Ajouté ✅');
        if (res.ok) {
          list.replaceChildren();
          $('q').value = '';
          refresh();
        } else {
          add.disabled = false;
        }
      };
      return item(v, add);
    }));
    if (!list.children.length) list.innerHTML = '<li class="empty">Rien trouvé, essaie autrement.</li>';
  } catch {
    list.innerHTML = '<li class="empty">Le PC ne répond pas.</li>';
  }
};

// ------------------------------------------------------------ File
async function refresh() {
  try {
    const st = await (await fetch(q('etat'), { cache: 'no-store' })).json();
    $('now-title').textContent = st.en_cours ? st.en_cours.titre : 'Rien pour l\'instant';
    document.querySelector('.eq').classList.toggle('off', !st.en_cours);
    const list = $('queue');
    list.replaceChildren(...(st.file || []).map((s) => {
      const v = document.createElement('button');
      v.className = s.moi ? 'voted' : 'ghost';
      v.textContent = `👍 ${s.votes}`;
      v.onclick = async () => {
        await post('voter', { id: s.id });
        refresh();
      };
      return item(s, v);
    }));
    if (!list.children.length) list.innerHTML = '<li class="empty">La file est vide : ajoute le premier son !</li>';
  } catch {
    $('now-title').textContent = 'La soirée est terminée (ou le PC ne répond plus).';
  }
}
refresh();
setInterval(() => { if (!document.hidden) refresh(); }, 3000);
