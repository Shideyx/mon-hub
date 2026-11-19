// Réalité augmentée de Mon Hub : un hologramme 3D dans l'image de la
// caméra, qu'on touche, attrape, tourne et agrandit avec les doigts (vision
// des mains MediaPipe, sur l'appareil). Il peut aussi tenir sur la main ou
// sortir d'un marqueur posé sur la table (js-aruco2). Les images de la
// caméra ne quittent jamais l'appareil.
import * as THREE from './vendor/three.min.js';
import { OBJECTS, buildObject, buildCustom } from './objects.js';
import { focalFor, PoseSmoother, palmPose, betweenHands, markerPose, basisFromUp } from './track.js';
import { setHolo, tickHolo, makeProjector, makeFingertip, holoSkin, holoWire } from './holo.js';

const $ = (id) => document.getElementById(id);
const video = $('cam');
const stage = $('stage');
const glCanvas = $('gl');
const params = new URLSearchParams(location.search);
const bridge = () => window.flutter_inappwebview;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const MODES = ['air', 'main', 'table'];

const state = {
  mode: MODES.includes(params.get('mode')) ? params.get('mode') : 'air',
  object: params.get('objet') || 'dino',
  holo: params.get('style') !== 'reel',
  stream: null,
  devices: [],
  deviceIndex: -1,
  mirror: true,
  W: 1280,
  H: 720,
  focal: focalFor(1280, 720),
  hands: null,
  handsLoading: null,
  handsError: null,
  detector: null,
  posit: null,
};

// ------------------------------------------------------------ La scène 3D
const renderer = new THREE.WebGLRenderer({ canvas: glCanvas, alpha: true, antialias: true });
renderer.outputColorSpace = THREE.SRGBColorSpace;
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.setClearColor(0x000000, 0);
const scene = new THREE.Scene();
scene.environment = new THREE.PMREMGenerator(renderer).fromScene(new THREE.RoomEnvironment(), 0.04).texture;
const camera = new THREE.PerspectiveCamera(45, 16 / 9, 0.01, 1000);
const hemi = new THREE.HemisphereLight(0xffffff, 0x3a3550, 1.0);
const sun = new THREE.DirectionalLight(0xffffff, 1.6);
sun.position.set(0.6, 2, 1.2);
scene.add(hemi, sun);

// anchor (où : air, main, table) → holder (apparition × taille choisie)
// → spinner (rotation donnée du doigt) → l'objet.
const anchor = new THREE.Group();
anchor.visible = false;
scene.add(anchor);
const holder = new THREE.Group();
anchor.add(holder);
const spinner = new THREE.Group();
holder.add(spinner);

// Ombre douce (vraies couleurs) ou socle projecteur (hologramme).
const shadowTex = (() => {
  const c = document.createElement('canvas');
  c.width = c.height = 128;
  const g = c.getContext('2d');
  const grd = g.createRadialGradient(64, 64, 0, 64, 64, 64);
  grd.addColorStop(0, 'rgba(0,0,0,0.55)');
  grd.addColorStop(0.45, 'rgba(0,0,0,0.25)');
  grd.addColorStop(1, 'rgba(0,0,0,0)');
  g.fillStyle = grd;
  g.fillRect(0, 0, 128, 128);
  return new THREE.CanvasTexture(c);
})();
const shadow = new THREE.Mesh(
  new THREE.CircleGeometry(0.55, 48),
  new THREE.MeshBasicMaterial({ map: shadowTex, transparent: true, depthWrite: false }),
);
shadow.rotation.x = -Math.PI / 2;
shadow.position.y = 0.003;
shadow.renderOrder = -1;
holder.add(shadow);
const projector = makeProjector();
holder.add(projector.group);

// Points lumineux au bout des doigts.
const tips = [0, 1, 2, 3].map(() => {
  const s = makeFingertip();
  s.visible = false;
  scene.add(s);
  return s;
});

let current = null;

function dispose(obj) {
  obj.traverse((o) => {
    if (!o.userData.holoPart) o.geometry?.dispose?.();
    for (const m of [o.material, o.userData.real].flat()) {
      if (!m || m === holoSkin || m === holoWire) continue;
      for (const v of Object.values(m)) if (v && v.isTexture) v.dispose();
      m.dispose();
    }
  });
}

function applyStyle() {
  if (current) setHolo(current.group, state.holo);
  projector.group.visible = state.holo;
  shadow.visible = !state.holo;
  $('btn-style').textContent = state.holo ? '🎨' : '✨';
  $('btn-style').title = state.holo ? 'Vraies couleurs' : 'Hologramme';
}

function setObject(id, recipe) {
  if (current) {
    spinner.remove(current.group);
    dispose(current.group);
  }
  current = recipe ? buildCustom(recipe) : buildObject(id);
  state.object = recipe ? 'custom' : OBJECTS.some((o) => o.id === id) ? id : 'dino';
  spinner.add(current.group);
  pop.x = Math.min(pop.x, 0.2);
  applyStyle();
  renderChips();
}

// ------------------------------------------------------------ Les boutons
function renderChips() {
  const box = $('objects');
  box.replaceChildren(
    ...OBJECTS.map((o) => {
      const b = document.createElement('button');
      b.className = 'chip' + (o.id === state.object ? ' on' : '');
      b.innerHTML = `<span class="e">${o.emoji}</span>`;
      b.append(o.label);
      b.onclick = () => setObject(o.id);
      return b;
    }),
  );
}

let hintUntil = 0;
let hintText = '';
function setHint(text, ms = 0) {
  const now = performance.now();
  if (!ms && now < hintUntil) return;
  if (ms) hintUntil = now + ms;
  if (text === hintText) return;
  hintText = text;
  const el = $('hint');
  el.hidden = !text;
  if (text) {
    el.textContent = text;
    el.style.animation = 'none';
    void el.offsetWidth;
    el.style.animation = '';
  }
}

function showProgress(fraction) {
  $('progress').hidden = fraction == null;
  if (fraction != null) $('progress-bar').style.width = `${Math.round(fraction * 100)}%`;
}

function setMode(mode) {
  state.mode = MODES.includes(mode) ? mode : 'air';
  for (const b of document.querySelectorAll('#modes button')) b.classList.toggle('on', b.dataset.mode === state.mode);
  smoother.reset();
  target = null;
  hidden = false;
  hintUntil = 0;
  gest.grab = null;
  gest.duo = null;
  if (state.mode === 'air') resetAir();
  ensureHands().catch(() => {});
}

for (const b of document.querySelectorAll('#modes button')) b.onclick = () => setMode(b.dataset.mode);
$('btn-style').onclick = () => {
  state.holo = !state.holo;
  applyStyle();
};
$('btn-marker').onclick = () => ($('sheet').hidden = false);
$('btn-close').onclick = () => ($('sheet').hidden = true);
$('btn-print').onclick = () => window.print();
$('btn-retry').onclick = () => startCamera();
$('btn-photo').onclick = () => (wantPhoto = true);
$('btn-cam').onclick = () => {
  if (state.devices.length < 2) return;
  state.deviceIndex = (state.deviceIndex + 1) % state.devices.length;
  startCamera();
};
$('marker-svg').innerHTML = new AR.Dictionary('ARUCO_MIP_36h12').generateSVG(0);

// Les objets connus, reconnus dans une phrase (« un dinosaure », « le soleil »…).
const KNOWN = [
  ['dino', /\bt ?rex\b|\bdino|\btyrannosaure\b/],
  ['clicky', /\bclicky\b|\bfleche\b|\bcurseur\b/],
  ['systeme', /systeme solaire|\bsoleil\b|\bplanetes\b/],
  ['planete', /\bplanete\b|\bsaturne\b/],
  ['coeur', /\bcoeur\b/],
  ['fusee', /\bfusee\b/],
  ['diamant', /\bdiamant\b|\bpierre precieuse\b/],
  ['cube', /\bcube\b|\brubik/],
];
export function matchKnown(text) {
  const n = text.toLowerCase().replace(/œ/g, 'oe').normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[-']/g, ' ');
  return KNOWN.find(([, re]) => re.test(n))?.[0] ?? null;
}

$('invent').onsubmit = async (e) => {
  e.preventDefault();
  const input = $('invent-text');
  const text = input.value.trim();
  if (!text) return;
  const known = matchKnown(text);
  if (known) {
    setObject(known);
    input.value = '';
    return;
  }
  const b = bridge();
  if (!b?.callHandler) {
    setHint('Ouvre la réalité augmentée dans Mon Hub pour que Clicky invente des objets.', 4000);
    return;
  }
  const form = $('invent');
  form.classList.add('busy');
  setHint(`Clicky imagine « ${text} »…`, 30000);
  try {
    const r = await b.callHandler('invent', text);
    if (r && Array.isArray(r.pieces) && r.pieces.length) {
      setObject('custom', r);
      input.value = '';
      setHint(`Voilà : ${r.nom || text} ✨`, 3500);
    } else {
      setHint(r?.erreur || 'Je n\'ai pas réussi à l\'imaginer, essaie avec d\'autres mots.', 5000);
    }
  } catch {
    setHint('Je n\'ai pas réussi à l\'imaginer.', 4000);
  } finally {
    form.classList.remove('busy');
  }
};

// Mon Hub (et Clicky) pilotent la page.
window.monHub = {
  setObject: (id) => setObject(id),
  setCustom: (recipe) => setObject('custom', recipe),
  setMode: (m) => setMode(m),
  setHolo: (on) => {
    state.holo = !!on;
    applyStyle();
  },
};

// ------------------------------------------------------------ La caméra
function stopCamera() {
  state.stream?.getTracks().forEach((t) => t.stop());
  state.stream = null;
}

function cameraError(e) {
  const name = e?.name || '';
  let title = 'Pas de caméra';
  let text = 'Je n\'arrive pas à ouvrir la caméra.';
  if (name === 'NotAllowedError' || name === 'SecurityError') {
    title = 'Caméra bloquée';
    text = 'Windows empêche Mon Hub d\'utiliser la caméra. Ouvre Paramètres → Confidentialité et sécurité → Caméra, '
      + 'active « Accès à la caméra » et « Autoriser les applications de bureau à accéder à votre caméra », puis réessaie.';
  } else if (name === 'NotFoundError' || name === 'OverconstrainedError') {
    text = 'Aucune caméra trouvée. Branche une webcam, puis réessaie.';
  } else if (name === 'NotReadableError' || name === 'AbortError') {
    title = 'Caméra occupée';
    text = 'Une autre appli utilise déjà la caméra (Discord, Teams, l\'appli Caméra…). Ferme-la, puis réessaie.';
  }
  $('error-title').textContent = title;
  $('error-text').textContent = text;
  $('error').hidden = false;
}

async function startCamera() {
  $('error').hidden = true;
  stopCamera();
  if (!navigator.mediaDevices?.getUserMedia) return cameraError({ name: 'NotFoundError' });
  const v = { width: { ideal: 1280 }, height: { ideal: 720 } };
  const dev = state.devices[state.deviceIndex];
  if (dev?.deviceId) v.deviceId = { exact: dev.deviceId };
  else v.facingMode = 'user';
  try {
    state.stream = await navigator.mediaDevices.getUserMedia({ video: v, audio: false });
  } catch (e) {
    return cameraError(e);
  }
  video.srcObject = state.stream;
  await video.play().catch(() => {});
  for (let i = 0; i < 50 && !video.videoWidth; i++) await sleep(50);
  const track = state.stream.getVideoTracks()[0];
  const settings = track?.getSettings?.() || {};
  state.mirror = settings.facingMode !== 'environment';
  try {
    state.devices = (await navigator.mediaDevices.enumerateDevices()).filter((d) => d.kind === 'videoinput');
  } catch {
    state.devices = [];
  }
  if (state.deviceIndex < 0) state.deviceIndex = Math.max(0, state.devices.findIndex((d) => d.deviceId === settings.deviceId));
  $('btn-cam').hidden = state.devices.length < 2;
  layout();
}

function layout() {
  const W = video.videoWidth || 1280;
  const H = video.videoHeight || 720;
  const resized = W !== state.W || H !== state.H;
  state.W = W;
  state.H = H;
  state.focal = focalFor(W, H);
  const vw = window.innerWidth;
  const vh = window.innerHeight;
  const k = Math.max(vw / W, vh / H);
  const cw = Math.round(W * k);
  const ch = Math.round(H * k);
  Object.assign(stage.style, { width: `${cw}px`, height: `${ch}px`, left: `${(vw - cw) / 2}px`, top: `${(vh - ch) / 2}px` });
  stage.classList.toggle('mirror', state.mirror);
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 1920 / cw));
  renderer.setSize(cw, ch, false);
  camera.aspect = W / H;
  camera.fov = THREE.MathUtils.radToDeg(2 * Math.atan(H / 2 / state.focal));
  camera.updateProjectionMatrix();
  state.posit = new POS.Posit(1.0, state.focal);
  if (resized && state.mode === 'air' && !gest.moved) resetAir();
}
window.addEventListener('resize', layout);

// ------------------------------------------------- La vision des mains
async function prepareFiles() {
  let st;
  try {
    st = await (await fetch('/mp/prepare', { method: 'POST' })).json();
  } catch {
    return; // Pas de serveur Mon Hub : les fichiers sont déjà là.
  }
  while (!st.ready) {
    if (st.error) throw new Error(st.error);
    const mb = (n) => (n / 1e6).toFixed(1).replace('.', ',');
    setHint(st.total ? `Je prépare la vision des mains : ${mb(st.received)} / ${mb(st.total)} Mo (une seule fois)` : 'Je prépare la vision des mains…');
    showProgress(st.total ? st.received / st.total : 0);
    await sleep(300);
    st = await (await fetch('/mp/status')).json();
  }
  showProgress(null);
}

function ensureHands() {
  if (state.hands) return Promise.resolve(state.hands);
  if (state.handsLoading) return state.handsLoading;
  state.handsError = null;
  state.handsLoading = (async () => {
    try {
      await prepareFiles();
      setHint('J\'allume la vision des mains…');
      const vision = await import('/mp/vision_bundle.mjs');
      const files = await vision.FilesetResolver.forVisionTasks(new URL('/mp/wasm', location.href).href);
      const options = (delegate) => ({
        baseOptions: { modelAssetPath: '/mp/hand_landmarker.task', delegate },
        runningMode: 'VIDEO',
        numHands: 2,
        minHandDetectionConfidence: 0.5,
        minHandPresenceConfidence: 0.5,
        minTrackingConfidence: 0.5,
      });
      try {
        state.hands = await vision.HandLandmarker.createFromOptions(files, options('GPU'));
      } catch {
        state.hands = await vision.HandLandmarker.createFromOptions(files, options('CPU'));
      }
      hintUntil = 0;
      hintText = '';
      return state.hands;
    } catch (e) {
      state.handsError = String(e?.message || e);
      showProgress(null);
      throw e;
    } finally {
      state.handsLoading = null;
    }
  })();
  return state.handsLoading;
}

let lastTs = 0;
let lastHands = [];
function detectHands(now) {
  // window.__fakeHands : mains simulées pour les tests automatiques.
  const source = window.__fakeHands ? { detectForVideo: () => ({ landmarks: window.__fakeHands() }) } : state.hands;
  if (!source) return [];
  const ts = Math.max(now, lastTs + 1);
  lastTs = ts;
  let res;
  try {
    res = source.detectForVideo(video, ts);
  } catch {
    return [];
  }
  return (lastHands = (res?.landmarks || []).map((l, i) => {
    const h = palmPose(l, state.W, state.H, state.focal);
    const label = res.handedness?.[i]?.[0]?.categoryName || '';
    h.id = label && !(res.handedness || []).some((o, j) => j !== i && o?.[0]?.categoryName === label) ? label : `main${i}`;
    // Pincement avec « hystérésis » : il faut bien pincer pour commencer,
    // et bien relâcher pour lâcher (pas de clignotement).
    const was = pinchState.get(h.id) || false;
    h.pinching = was ? h.pinchRatio < 0.45 : h.pinchRatio < 0.27;
    h.pinchStart = h.pinching && !was;
    return h;
  }));
}

// ------------------------------------------------------- Les gestes
const pinchState = new Map();
const lastIndex = new Map();
const gest = { grab: null, duo: null, spin: 0, yaw: 0, scale: 1, moved: false, used: false };
const air = { position: new THREE.Vector3(), scale: 1.3 };

function resetAir() {
  // Devant la caméra, à hauteur de main, à peu près au centre.
  air.position.set(0, -0.65, -5.5);
  air.scale = 1.3;
}

/// Où est l'objet à l'écran (en pixels de la vidéo), et sa taille.
function objectOnScreen() {
  const centre = new THREE.Vector3(0, 0.5, 0);
  holder.localToWorld(centre);
  const depth = Math.max(0.1, -centre.z);
  const ndc = centre.clone().project(camera);
  const k = anchor.scale.x * holder.scale.x;
  return { x: ((ndc.x + 1) / 2) * state.W, y: ((1 - ndc.y) / 2) * state.H, r: (state.focal * 0.55 * k) / depth };
}

function interact(hands, t, dt, carrier) {
  for (const h of hands) pinchState.set(h.id, h.pinching);
  for (const id of [...pinchState.keys()]) if (!hands.some((h) => h.id === id)) pinchState.delete(id);
  const obj = objectOnScreen();
  const near = (p, f) => Math.hypot(p.x - obj.x, p.y - obj.y) < obj.r * f;

  // Deux mains qui pincent : écarter = agrandir, tourner = faire pivoter.
  const pinching = hands.filter((h) => h.pinching);
  if (pinching.length >= 2) {
    const [a, b] = pinching;
    const d = Math.hypot(a.pinchPx.x - b.pinchPx.x, a.pinchPx.y - b.pinchPx.y);
    const ang = Math.atan2(b.pinchPx.y - a.pinchPx.y, b.pinchPx.x - a.pinchPx.x);
    if (!gest.duo) gest.duo = { d0: Math.max(20, d), a0: ang, s0: gest.scale, y0: gest.yaw };
    let da = ang - gest.duo.a0;
    da = Math.atan2(Math.sin(da), Math.cos(da));
    gest.scale = Math.min(5, Math.max(0.3, (gest.duo.s0 * d) / gest.duo.d0));
    gest.yaw = gest.duo.y0 - da * 1.5;
    gest.spin = 0;
    gest.grab = null;
    gest.used = true;
    setHint('Écarte les mains pour l\'agrandir, tourne-les pour le faire pivoter', 1200);
    return;
  }
  gest.duo = null;

  // Une main qui pince près de l'objet : on l'attrape (dans l'air).
  if (state.mode === 'air') {
    const p = pinching.find((h) => h.pinchStart && near(h.pinchPx, 1.6));
    if (p && !gest.grab) {
      // On garde l'écart vu à l'écran entre les doigts et l'objet : il reste
      // collé aux doigts, et s'éloigne ou se rapproche avec la main.
      const pd = -p.pinch3d.z;
      const od = -air.position.z;
      gest.grab = {
        id: p.id,
        hand0: pd,
        obj0: od,
        ox: air.position.x / od - p.pinch3d.x / pd,
        oy: air.position.y / od - p.pinch3d.y / pd,
      };
      gest.spin = 0;
    }
    if (gest.grab) {
      const g = pinching.find((h) => h.id === gest.grab.id);
      if (!g) {
        gest.grab = null;
      } else {
        const gr = gest.grab;
        const hd = -g.pinch3d.z;
        const d = Math.min(20, Math.max(1.5, (gr.obj0 * hd) / gr.hand0));
        const want = new THREE.Vector3((g.pinch3d.x / hd + gr.ox) * d, (g.pinch3d.y / hd + gr.oy) * d, -d);
        air.position.lerp(want, 0.6);
        gest.moved = true;
        gest.used = true;
        setHint('Attrapé ! Relâche les doigts pour le poser 🤏', 900);
      }
    }
  }

  // Le bout de l'index qui glisse sur l'objet : il tourne (avec élan).
  for (const h of hands) {
    const prev = lastIndex.get(h.id);
    lastIndex.set(h.id, h.indexPx);
    if (!prev || h.pinching || h === carrier || gest.grab) continue;
    if (!near(h.indexPx, 1.15)) continue;
    const vx = (h.indexPx.x - prev.x) / Math.max(dt, 1 / 120);
    if (Math.abs(vx) < 40) continue;
    const want = Math.max(-14, Math.min(14, vx / Math.max(30, obj.r)));
    gest.spin = Math.abs(want) > Math.abs(gest.spin) || Math.sign(want) !== Math.sign(gest.spin) ? want : gest.spin;
    gest.used = true;
  }
  for (const id of [...lastIndex.keys()]) if (!hands.some((h) => h.id === id)) lastIndex.delete(id);
}

function showFingertips(hands) {
  let i = 0;
  for (const h of hands.slice(0, 2)) {
    const pts = h.pinching ? [h.pinch3d] : [h.index, h.thumb];
    for (const p of pts) {
      const s = tips[i++];
      s.visible = true;
      s.position.copy(p);
      const k = (h.pinching ? 0.75 : 0.45) * (-p.z / 5.5);
      s.scale.setScalar(k);
      s.material.opacity = h.pinching ? 1 : 0.8;
    }
  }
  for (; i < tips.length; i++) tips[i].visible = false;
}

// ------------------------------------------------------- Le suivi
const smoother = new PoseSmoother();
let target = null;
let seenAt = -1;
let hidden = false;
let lastVideoTime = -1;
let prevUp = null;
let tipsShown = false;
const proc = document.createElement('canvas');
const pctx = proc.getContext('2d', { willReadFrequently: true });

function waitingForHands() {
  if (state.hands) return false;
  if (state.handsError) {
    setHint('La vision des mains n\'a pas pu se préparer (internet ?). Clique sur le mode pour réessayer.');
  } else if (!state.handsLoading) {
    ensureHands().catch(() => {});
  }
  return true;
}

function palmAnchor(hands) {
  if (!hands.length) {
    hidden = false;
    setHint('Montre ta main ouverte à la caméra 🖐️');
    return null;
  }
  const open = hands.filter((h) => h.open && !h.pinching);
  if (!open.length) {
    hidden = true;
    setHint('Ouvre la main pour le faire réapparaître ✋');
    return null;
  }
  hidden = false;
  if (open.length >= 2) {
    setHint('Écarte les mains pour l\'agrandir 👐');
    return { pose: betweenHands(open[0], open[1]), carrier: null };
  }
  if (!tipsShown) {
    tipsShown = true;
    setHint('Ferme la main pour le cacher. Avec l\'autre main, touche-le du doigt pour le faire tourner.', 6000);
  } else {
    setHint('');
  }
  return { pose: open[0], carrier: open[0] };
}

function trackMarker() {
  if (!state.posit || typeof AR === 'undefined') return null;
  const pw = Math.min(640, state.W);
  const ph = Math.round((pw * state.H) / state.W);
  if (proc.width !== pw || proc.height !== ph) {
    proc.width = pw;
    proc.height = ph;
  }
  pctx.drawImage(video, 0, 0, pw, ph);
  state.detector ||= new AR.Detector({ dictionaryName: 'ARUCO_MIP_36h12' });
  const markers = state.detector.detect(pctx.getImageData(0, 0, pw, ph));
  if (!markers.length) {
    setHint('Montre le marqueur à la caméra : bouton 🔳 pour l\'afficher sur ton téléphone ou l\'imprimer');
    return null;
  }
  setHint('');
  const m = markers.find((x) => x.id === 0) || markers[0];
  const k = state.W / pw;
  const corners = m.corners.map((c) => ({ x: c.x * k - state.W / 2, y: state.H / 2 - c.y * k }));
  const p = state.posit.pose(corners);
  const pose = markerPose(
    [
      { rotation: p.bestRotation, translation: p.bestTranslation, error: p.bestError },
      { rotation: p.alternativeRotation, translation: p.alternativeTranslation, error: p.alternativeError },
    ],
    prevUp,
  );
  if (!pose) return null;
  prevUp = pose.up;
  pose.scale = 1.25;
  return pose;
}

function airHint(hands) {
  if (gest.used) return setHint('');
  if (waitingForHands()) return;
  setHint(hands.length
    ? 'Glisse ton index dessus pour le faire tourner, pince-le (pouce + index) pour l\'attraper 🤏'
    : 'Montre ta main à la caméra : tu vas pouvoir le toucher 👆');
}

function track(now, t, dt) {
  if (video.readyState < 2 || video.currentTime === lastVideoTime) return;
  lastVideoTime = video.currentTime;
  const hands = detectHands(now);
  let pose = null;
  let carrier = null;
  if (state.mode === 'air') {
    airHint(hands);
  } else if (state.mode === 'main') {
    if (!waitingForHands()) {
      const r = palmAnchor(hands);
      pose = r?.pose || null;
      carrier = r?.carrier || null;
    }
  } else {
    pose = trackMarker();
  }
  interact(hands, t, dt, carrier);
  showFingertips(hands);
  if (pose) {
    if (t - seenAt > 0.6) smoother.reset();
    seenAt = t;
    target = smoother.apply(pose, t);
  }
}

// ---------------------------------------- Lumière de la pièce (estimée)
const probe = document.createElement('canvas');
probe.width = 16;
probe.height = 9;
const probeCtx = probe.getContext('2d', { willReadFrequently: true });
let lastProbe = 0;
function updateLight(t) {
  if (state.holo || t - lastProbe < 0.5 || video.readyState < 2) return;
  lastProbe = t;
  probeCtx.drawImage(video, 0, 0, 16, 9);
  const d = probeCtx.getImageData(0, 0, 16, 9).data;
  let r = 0;
  let g = 0;
  let b = 0;
  for (let i = 0; i < d.length; i += 4) {
    r += d[i];
    g += d[i + 1];
    b += d[i + 2];
  }
  const n = d.length / 4;
  const lum = (0.2126 * r + 0.7152 * g + 0.0722 * b) / n / 255;
  hemi.color.set(0xffffff).lerp(new THREE.Color(r / n / 255, g / n / 255, b / n / 255), 0.25);
  hemi.intensity = 0.55 + lum * 1.1;
  sun.intensity = 0.9 + lum * 1.5;
  renderer.toneMappingExposure = 0.85 + lum * 0.4;
}

// ------------------------------------------------------------ La photo
let wantPhoto = false;
function takePhoto() {
  wantPhoto = false;
  const c = document.createElement('canvas');
  c.width = state.W;
  c.height = state.H;
  const g = c.getContext('2d');
  if (state.mirror) {
    g.translate(state.W, 0);
    g.scale(-1, 1);
  }
  g.drawImage(video, 0, 0, state.W, state.H);
  g.drawImage(glCanvas, 0, 0, state.W, state.H);
  const data = c.toDataURL('image/jpeg', 0.92);
  const flash = $('flash');
  flash.classList.add('on');
  requestAnimationFrame(() => requestAnimationFrame(() => flash.classList.remove('on')));
  const b = bridge();
  if (b?.callHandler) {
    b.callHandler('photo', data).then((r) => setHint(r || 'Photo enregistrée 📸', 4000), () => setHint('La photo n\'a pas pu être enregistrée.', 4000));
  } else {
    const a = document.createElement('a');
    a.href = data;
    a.download = 'realite-augmentee.jpg';
    a.click();
  }
}

// ------------------------------------------------------ La boucle d'images
// Apparition à ressort : l'objet « saute » en place, puis se stabilise.
const pop = { x: 0, v: 0 };
function stepPop(goal, dt) {
  const steps = 4;
  const h = dt / steps;
  for (let i = 0; i < steps; i++) {
    const a = 170 * (goal - pop.x) - 13 * pop.v;
    pop.v += a * h;
    pop.x += pop.v * h;
  }
  if (pop.x < 0) {
    pop.x = 0;
    pop.v = 0;
  }
}

let lastT = performance.now() / 1000;
function frame(now) {
  requestAnimationFrame(frame);
  const t = now / 1000;
  const dt = Math.min(0.1, Math.max(0, t - lastT));
  lastT = t;
  track(now, t, dt);
  let visible;
  if (state.mode === 'air') {
    visible = true;
    anchor.position.copy(air.position);
    anchor.quaternion.copy(basisFromUp(new THREE.Vector3(0, 1, 0), air.position));
    anchor.scale.setScalar(air.scale);
  } else {
    visible = !!target && !hidden && t - seenAt < 0.4;
    if (target) {
      anchor.position.copy(target.position);
      anchor.quaternion.copy(target.quaternion);
      anchor.scale.setScalar(target.scale);
    }
  }
  stepPop(visible ? 1 : 0, dt);
  anchor.visible = pop.x > 0.01;
  holder.scale.setScalar(Math.max(0.0001, pop.x * gest.scale));
  // La rotation donnée du doigt, qui ralentit doucement.
  gest.yaw += gest.spin * dt;
  gest.spin *= Math.exp(-dt * 1.1);
  if (Math.abs(gest.spin) < 0.02) gest.spin = 0;
  spinner.rotation.y = gest.yaw;
  current?.update(t, dt);
  if (state.holo) projector.update(t, dt);
  tickHolo(t);
  updateLight(t);
  renderer.render(scene, camera);
  if (wantPhoto) takePhoto();
  window.__ar = { visible: anchor.visible, mode: state.mode, objet: state.object, hands: !!state.hands, error: state.handsError, screen: objectOnScreen(),
    geste: { tour: +gest.yaw.toFixed(2), elan: +gest.spin.toFixed(2), taille: +gest.scale.toFixed(2), attrape: !!gest.grab },
    mains: lastHands.map((h) => ({ id: h.id, reach: +h.reach.toFixed(2), pince: +h.pinchRatio.toFixed(2), taille: Math.round(h.sizePx), ouverte: h.open })) };
}

resetAir();
renderChips();
setObject(state.object);
setMode(state.mode);
startCamera();
requestAnimationFrame(frame);
