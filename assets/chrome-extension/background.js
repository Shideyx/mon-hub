// Mon Hub — Smily dans le navigateur.
//
// L'extension se relie à Mon Hub, sur ce PC uniquement (ws://127.0.0.1),
// et exécute ce que Smily demande : lister les onglets, ouvrir un onglet à
// lui (en arrière-plan, dans le groupe « Smily »), lire une page, cliquer,
// écrire. Rien n'est envoyé sur internet par l'extension.
//
// Garde-fous : jamais sur les pages de banque, de paiement, de mots de passe
// ou de sécurité du compte ; jamais de saisie dans un champ mot de passe ;
// Mon Hub demande ton accord avant d'envoyer, publier, payer ou supprimer.

const PORT = 47614;
const URL_MONHUB = `ws://127.0.0.1:${PORT}/navigateur`;

let ws = null;
let groupId = null;
const attached = new Map(); // onglet → minuteur de détachement du débogueur

// ---------------------------------------------------------------- Liaison

function connect() {
  if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) return;
  try {
    ws = new WebSocket(URL_MONHUB);
  } catch (e) {
    ws = null;
    return;
  }
  ws.onopen = () => {
    ws.send(JSON.stringify({ hello: 'monhub-chrome', version: chrome.runtime.getManifest().version }));
    chrome.action.setBadgeText({ text: 'ON' });
    chrome.action.setBadgeBackgroundColor({ color: '#10B981' });
  };
  ws.onclose = () => {
    ws = null;
    chrome.action.setBadgeText({ text: '' });
  };
  ws.onerror = () => {};
  ws.onmessage = async (event) => {
    let msg;
    try {
      msg = JSON.parse(event.data);
    } catch (e) {
      return;
    }
    if (msg.ping) {
      send({ pong: msg.ping });
      return;
    }
    if (msg.id === undefined || !msg.cmd) return;
    try {
      const result = await run(msg.cmd, msg.args || {});
      send({ id: msg.id, ok: true, result });
    } catch (e) {
      send({ id: msg.id, ok: false, error: String(e && e.message ? e.message : e) });
    }
  };
}

function send(obj) {
  if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj));
}

// Le service de l'extension s'endort : on le réveille toutes les 30 s pour
// se reconnecter à Mon Hub s'il vient d'être ouvert.
chrome.alarms.create('monhub', { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener(() => connect());
chrome.runtime.onStartup.addListener(() => connect());
chrome.runtime.onInstalled.addListener(() => connect());
chrome.action.onClicked.addListener(() => connect());
connect();

// -------------------------------------------------------------- Sécurité

const BLOCKED = [
  /^(chrome|edge|about|chrome-extension|extension|devtools|view-source|file):/i,
  /:\/\/(accounts|myaccount|passwords|pay|payments)\.google\./i,
  /:\/\/([^/]*\.)?(paypal|stripe|lydia-app|revolut|boursorama|bnpparibas|mabanque|credit-agricole|ca-[a-z-]+|societegenerale|lcl|caisse-epargne|banquepopulaire|labanquepostale|creditmutuel|cic|hellobank|fortuneo|n26|qonto|shine|ing|monabanq|bankin|sumeria)\./i,
  /:\/\/([^/]*\.)?(bitwarden|1password|lastpass|dashlane|keepass|nordpass)\./i,
  /:\/\/([^/]*\.)?(account\.microsoft|login\.live|appleid\.apple|id\.apple)\./i,
  /checkout|\/paiement|\/payment|\/billing|\/facturation/i,
];

function blocked(url) {
  return !url || BLOCKED.some((r) => r.test(url));
}

async function tabOf(id) {
  const tab = await chrome.tabs.get(Number(id));
  if (blocked(tab.url || tab.pendingUrl)) {
    throw "Page protégée (banque, paiement, mots de passe ou compte) : Smily n'y touche pas.";
  }
  return tab;
}

// ------------------------------------------------------------- Commandes

async function run(cmd, a) {
  switch (cmd) {
    case 'tabs': {
      const tabs = await chrome.tabs.query({});
      return tabs.map((t) => ({
        id: t.id,
        titre: t.title,
        url: blocked(t.url) ? '(page protégée)' : t.url,
        actif: t.active,
        clicky: groupId !== null && t.groupId === groupId,
      }));
    }
    case 'open': {
      const url = String(a.url || '');
      if (!/^https?:\/\//i.test(url) || blocked(url)) throw 'Adresse refusée : ' + url;
      const tab = await chrome.tabs.create({ url, active: a.background === false });
      await addToGroup(tab.id);
      await waitLoaded(tab.id);
      const t = await chrome.tabs.get(tab.id);
      return { id: t.id, titre: t.title, url: t.url };
    }
    case 'read': {
      const tab = await tabOf(a.tab);
      await waitLoaded(tab.id);
      const [r] = await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: snapshot, args: [Number(a.max || 15000)] });
      return r.result;
    }
    case 'describe': {
      const tab = await tabOf(a.tab);
      const [r] = await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: describeEl, args: [String(a.el)] });
      return r.result;
    }
    case 'click': {
      const tab = await tabOf(a.tab);
      const [r] = await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: clickEl, args: [String(a.el)] });
      if (r.result && r.result.error) throw r.result.error;
      if (r.result && r.result.trusted) {
        // Un vrai clic de souris (les sites qui ignorent les clics simulés).
        await trustedClick(tab.id, r.result.x, r.result.y);
      }
      await sleep(400);
      await waitLoaded(tab.id);
      return { ok: true };
    }
    case 'type': {
      const tab = await tabOf(a.tab);
      const [r] = await chrome.scripting.executeScript({
        target: { tabId: tab.id },
        func: typeEl,
        args: [a.el === undefined || a.el === null ? '' : String(a.el), String(a.text || ''), a.replace !== false],
      });
      if (r.result && r.result.error) throw r.result.error;
      if (r.result && r.result.needKeyboard) {
        // Éditeurs « riches » (Google Docs, Slides…) : du vrai texte tapé.
        await cdp(tab.id, 'Input.insertText', { text: String(a.text || '') });
      }
      if (a.enter) await key(tab.id, 'Enter');
      return { ok: true };
    }
    case 'key': {
      const tab = await tabOf(a.tab);
      await key(tab.id, String(a.key || 'Enter'));
      return { ok: true };
    }
    case 'close': {
      const tab = await chrome.tabs.get(Number(a.tab));
      await chrome.tabs.remove(tab.id);
      return { ok: true };
    }
    case 'focus': {
      const tab = await tabOf(a.tab);
      await chrome.tabs.update(tab.id, { active: true });
      await chrome.windows.update(tab.windowId, { focused: true });
      return { ok: true };
    }
    default:
      throw 'Commande inconnue : ' + cmd;
  }
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

async function waitLoaded(tabId, timeout = 20000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    const t = await chrome.tabs.get(tabId);
    if (t.status === 'complete') return;
    await sleep(250);
  }
}

async function addToGroup(tabId) {
  try {
    if (groupId !== null) {
      try {
        await chrome.tabGroups.get(groupId);
      } catch (e) {
        groupId = null;
      }
    }
    if (groupId === null) {
      groupId = await chrome.tabs.group({ tabIds: [tabId] });
      await chrome.tabGroups.update(groupId, { title: 'Smily', color: 'blue' });
    } else {
      await chrome.tabs.group({ tabIds: [tabId], groupId });
    }
  } catch (e) {}
}

// --------------------------------------------------- Débogueur (vrai clavier)

async function cdp(tabId, method, params) {
  if (!attached.has(tabId)) {
    await chrome.debugger.attach({ tabId }, '1.3');
  }
  clearTimeout(attached.get(tabId));
  // Détaché après 30 s sans rien faire (le bandeau jaune disparaît).
  attached.set(
    tabId,
    setTimeout(() => {
      chrome.debugger.detach({ tabId }).catch(() => {});
      attached.delete(tabId);
    }, 30000),
  );
  return chrome.debugger.sendCommand({ tabId }, method, params);
}

chrome.debugger.onDetach.addListener((src) => {
  if (src.tabId !== undefined) {
    clearTimeout(attached.get(src.tabId));
    attached.delete(src.tabId);
  }
});

const KEYS = {
  enter: ['Enter', 'Enter', 13, '\r'],
  tab: ['Tab', 'Tab', 9, ''],
  escape: ['Escape', 'Escape', 27, ''],
  backspace: ['Backspace', 'Backspace', 8, ''],
  delete: ['Delete', 'Delete', 46, ''],
  arrowup: ['ArrowUp', 'ArrowUp', 38, ''],
  arrowdown: ['ArrowDown', 'ArrowDown', 40, ''],
  arrowleft: ['ArrowLeft', 'ArrowLeft', 37, ''],
  arrowright: ['ArrowRight', 'ArrowRight', 39, ''],
  pagedown: ['PageDown', 'PageDown', 34, ''],
  pageup: ['PageUp', 'PageUp', 33, ''],
  home: ['Home', 'Home', 36, ''],
  end: ['End', 'End', 35, ''],
};

async function key(tabId, combo) {
  const parts = combo.toLowerCase().split('+').map((p) => p.trim());
  let modifiers = 0;
  for (const p of parts.slice(0, -1)) {
    if (p === 'alt') modifiers |= 1;
    if (p === 'ctrl' || p === 'control') modifiers |= 2;
    if (p === 'meta' || p === 'cmd') modifiers |= 4;
    if (p === 'shift' || p === 'maj') modifiers |= 8;
  }
  const last = parts[parts.length - 1];
  let def = KEYS[last];
  if (!def && last.length === 1) def = [last, 'Key' + last.toUpperCase(), last.toUpperCase().charCodeAt(0), modifiers ? '' : last];
  if (!def) throw 'Touche inconnue : ' + combo;
  const [k, code, vk, text] = def;
  await cdp(tabId, 'Input.dispatchKeyEvent', { type: text ? 'keyDown' : 'rawKeyDown', key: k, code, windowsVirtualKeyCode: vk, text, modifiers });
  await cdp(tabId, 'Input.dispatchKeyEvent', { type: 'keyUp', key: k, code, windowsVirtualKeyCode: vk, modifiers });
}

async function trustedClick(tabId, x, y) {
  for (const type of ['mouseMoved', 'mousePressed', 'mouseReleased']) {
    await cdp(tabId, 'Input.dispatchMouseEvent', { type, x, y, button: 'left', clickCount: 1 });
  }
}

// ------------------------------------------- Fonctions lancées dans la page

// Le texte de la page et ses éléments utilisables, numérotés.
function snapshot(max) {
  const sel =
    'a[href],button,input,textarea,select,summary,[role=button],[role=link],[role=textbox],[role=checkbox],' +
    '[role=radio],[role=menuitem],[role=tab],[role=option],[role=switch],[contenteditable=""],[contenteditable=true]';
  const visible = (el) => {
    const r = el.getBoundingClientRect();
    if (r.width < 2 || r.height < 2) return false;
    const s = getComputedStyle(el);
    return s.visibility !== 'hidden' && s.display !== 'none' && s.opacity !== '0';
  };
  const label = (el) =>
    (
      el.getAttribute('aria-label') ||
      (el.labels && el.labels[0] && el.labels[0].innerText) ||
      el.innerText ||
      el.value ||
      el.getAttribute('placeholder') ||
      el.getAttribute('title') ||
      el.getAttribute('alt') ||
      el.getAttribute('name') ||
      ''
    )
      .replace(/\s+/g, ' ')
      .trim()
      .slice(0, 90);
  document.querySelectorAll('[data-monhub]').forEach((el) => el.removeAttribute('data-monhub'));
  const elements = [];
  let n = 0;
  for (const el of document.querySelectorAll(sel)) {
    if (elements.length >= 200) break;
    if (!visible(el) || el.disabled) continue;
    n++;
    el.setAttribute('data-monhub', String(n));
    const tag = el.tagName.toLowerCase();
    const type = el.getAttribute('role') || (tag === 'input' ? 'champ ' + (el.type || 'text') : tag);
    const item = { n, type, texte: label(el) };
    if ((tag === 'input' || tag === 'textarea') && el.type !== 'password' && el.value) item.valeur = String(el.value).slice(0, 120);
    if (el.type === 'checkbox' || el.type === 'radio') item.coche = el.checked;
    if (tag === 'a' && el.href) item.lien = el.href.slice(0, 160);
    elements.push(item);
  }
  const text = (document.body ? document.body.innerText : '').replace(/\n{3,}/g, '\n\n').slice(0, max);
  return { titre: document.title, url: location.href, texte: text, elements };
}

// Attention : ces fonctions sont copiées dans la page une par une (elles ne
// voient pas le reste de ce fichier) : chacune cherche l'élément elle-même.

function describeEl(n) {
  const el = document.querySelector('[data-monhub="' + n + '"]');
  if (!el) return { texte: '' };
  const t = (el.getAttribute('aria-label') || el.innerText || el.value || el.getAttribute('title') || '').replace(/\s+/g, ' ').trim();
  return { texte: t.slice(0, 120), type: el.tagName.toLowerCase(), formulaire: !!el.closest('form') && (el.type === 'submit' || el.tagName === 'BUTTON') };
}

function clickEl(n) {
  const el = document.querySelector('[data-monhub="' + n + '"]');
  if (!el) return { error: "Élément introuvable : relis la page (nav_lire), elle a changé." };
  el.scrollIntoView({ block: 'center', inline: 'center' });
  const r = el.getBoundingClientRect();
  const x = Math.round(r.left + r.width / 2);
  const y = Math.round(r.top + r.height / 2);
  // Les liens, boutons et cases : un clic simple suffit. Les autres
  // éléments « maison » (menus de Google…) : un vrai clic de souris.
  const simple = ['A', 'BUTTON', 'INPUT', 'SELECT', 'SUMMARY', 'TEXTAREA', 'LABEL'].includes(el.tagName);
  if (simple) {
    el.focus();
    el.click();
    return { ok: true };
  }
  return { trusted: true, x, y };
}

function typeEl(n, text, replace) {
  const el = n ? document.querySelector('[data-monhub="' + n + '"]') : document.activeElement;
  if (!el) return { error: "Champ introuvable : relis la page (nav_lire)." };
  if (el.type === 'password' || /pass|mot.?de.?passe|code.?secret|cvc|cvv|iban/i.test(el.name + ' ' + el.id + ' ' + el.autocomplete)) {
    return { error: "Smily ne remplit jamais de mot de passe, de code ou de coordonnées bancaires." };
  }
  el.scrollIntoView({ block: 'center' });
  el.focus();
  const tag = el.tagName;
  if (tag === 'INPUT' || tag === 'TEXTAREA') {
    const proto = tag === 'INPUT' ? HTMLInputElement.prototype : HTMLTextAreaElement.prototype;
    const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
    setter.call(el, replace ? text : el.value + text);
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    return { ok: true };
  }
  if (tag === 'SELECT') {
    const opt = Array.from(el.options).find((o) => o.text.trim().toLowerCase() === text.trim().toLowerCase() || o.value === text);
    if (!opt) return { error: 'Choix introuvable dans la liste : ' + text };
    el.value = opt.value;
    el.dispatchEvent(new Event('change', { bubbles: true }));
    return { ok: true };
  }
  // Éditeur riche (contenteditable, Google Docs…) : texte tapé au clavier.
  if (replace && el.isContentEditable) {
    document.execCommand('selectAll', false);
  }
  return { needKeyboard: true };
}
