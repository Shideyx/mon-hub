// Réalité augmentée de Mon Hub : où poser l'objet 3D dans l'image.
//
// Repère de la scène (celui de three.js) : la caméra est à l'origine et
// regarde vers -Z, X vers la droite, Y vers le haut. Une unité = la taille
// de la paume (main) ou le côté du marqueur (table).
import * as THREE from './vendor/three.min.js';

/// Distance focale (en pixels) d'une webcam ordinaire : ~62° en largeur.
export function focalFor(width, height) {
  return Math.max(width, height) * 0.83;
}

/// Filtre « One Euro » : lisse les petits tremblements sans ajouter de
/// retard quand on bouge vite.
export class OneEuro {
  constructor(minCutoff = 1.2, beta = 0.02, dCutoff = 1.0) {
    this.minCutoff = minCutoff;
    this.beta = beta;
    this.dCutoff = dCutoff;
    this.x = null;
    this.dx = 0;
    this.t = 0;
  }

  static alpha(cutoff, dt) {
    const tau = 1 / (2 * Math.PI * cutoff);
    return 1 / (1 + tau / dt);
  }

  reset() {
    this.x = null;
  }

  filter(value, t) {
    if (this.x === null || t <= this.t) {
      this.x = value;
      this.dx = 0;
      this.t = t;
      return value;
    }
    const dt = Math.min(0.2, t - this.t);
    this.t = t;
    const dv = (value - this.x) / dt;
    this.dx += OneEuro.alpha(this.dCutoff, dt) * (dv - this.dx);
    const cutoff = this.minCutoff + this.beta * Math.abs(this.dx);
    this.x += OneEuro.alpha(cutoff, dt) * (value - this.x);
    return this.x;
  }
}

/// Lisse une pose complète (position, orientation, taille).
export class PoseSmoother {
  constructor() {
    this.p = [new OneEuro(1.0, 0.8), new OneEuro(1.0, 0.8), new OneEuro(1.0, 0.8)];
    this.s = new OneEuro(0.8, 0.5);
    this.q = null;
  }

  reset() {
    this.p.forEach((f) => f.reset());
    this.s.reset();
    this.q = null;
  }

  apply(pose, t) {
    const position = new THREE.Vector3(
      this.p[0].filter(pose.position.x, t),
      this.p[1].filter(pose.position.y, t),
      this.p[2].filter(pose.position.z, t),
    );
    const scale = this.s.filter(pose.scale, t);
    if (!this.q) {
      this.q = pose.quaternion.clone();
    } else {
      // Petit écart = beaucoup de lissage ; grand mouvement = on suit vite.
      const angle = this.q.angleTo(pose.quaternion);
      const k = Math.min(1, 0.18 + angle * 1.6);
      this.q.slerp(pose.quaternion, k);
    }
    return { position, quaternion: this.q.clone(), scale };
  }
}

const smoothstep = (a, b, x) => {
  const t = Math.min(1, Math.max(0, (x - a) / (b - a)));
  return t * t * (3 - 2 * t);
};

/// Une orientation à partir d'un axe « haut » : l'objet garde sa face vers
/// la caméra autant que possible.
export function basisFromUp(up, position, preferredForward) {
  const u = up.clone().normalize();
  let fwd = preferredForward ? preferredForward.clone() : position.clone().negate();
  fwd.addScaledVector(u, -fwd.dot(u));
  if (fwd.lengthSq() < 1e-6) {
    fwd = new THREE.Vector3(0, 0, 1).addScaledVector(u, -u.z);
    if (fwd.lengthSq() < 1e-6) fwd = new THREE.Vector3(0, -1, 0);
  }
  fwd.normalize();
  const right = new THREE.Vector3().crossVectors(u, fwd).normalize();
  const m = new THREE.Matrix4().makeBasis(right, u, fwd);
  return new THREE.Quaternion().setFromRotationMatrix(m);
}

// Points de la main (MediaPipe) : 0 poignet, 4 bout du pouce, 5/9/13/17
// bases de l'index/majeur/annulaire/auriculaire, 8/12/16/20 bouts des doigts.
const PALM = [0, 5, 9, 13, 17];
const TIPS = [8, 12, 16, 20];

/// Pose d'une main vue par la caméra. [lm] : 21 points normalisés (x, y
/// entre 0 et 1, z relatif à l'échelle de x), image [width] × [height].
export function palmPose(lm, width, height, focal) {
  // Points en pixels, axes de la caméra (x droite, y bas, z loin).
  const px = (i) => new THREE.Vector3(lm[i].x * width, lm[i].y * height, lm[i].z * width);
  const center = new THREE.Vector3();
  for (const i of PALM) center.add(px(i));
  center.divideScalar(PALM.length);

  // Taille de la paume, corrigée quand la main est penchée.
  const span = (a, b, real) => {
    const d = px(b).sub(px(a));
    const flat = Math.hypot(d.x, d.y);
    const full = d.length();
    const frac = full > 1e-6 ? Math.max(0.35, flat / full) : 1;
    return flat / frac / real;
  };
  const sizePx = Math.max(1, Math.max(span(0, 9, 1.0), span(5, 17, 0.8)));

  // Position 3D (une unité = la paume).
  const depth = focal / sizePx;
  const position = new THREE.Vector3(
    ((center.x - width / 2) * depth) / focal,
    (-(center.y - height / 2) * depth) / focal,
    -depth,
  );

  // Orientation : vecteurs passés dans le repère de la scène (y haut, z vers nous).
  const scene = (v) => new THREE.Vector3(v.x, -v.y, -v.z);
  const along = scene(px(9).sub(px(0))).normalize(); // poignet → doigts
  const across = scene(px(17).sub(px(5))).normalize(); // index → auriculaire
  const normal = new THREE.Vector3().crossVectors(along, across).normalize();
  // La face de la main tournée vers la caméra ou vers le haut.
  if (normal.dot(new THREE.Vector3(0, 0.6, 0.8)) < 0) normal.negate();
  // Paume à plat (vers le haut) : l'objet tient debout dessus ; main levée
  // face à la caméra : il se dresse dans le sens des doigts, devant la paume.
  const flat = smoothstep(0.35, 0.75, normal.y);
  const up = along.clone().lerp(normal, flat).normalize();
  const quaternion = basisFromUp(up, position);
  position.addScaledVector(normal, 0.18);

  // Main ouverte, fermée, pincée : mesurée en 3D (une main vue de profil
  // reste « ouverte »), par rapport à la longueur de la paume.
  const palmLen = Math.max(1, px(9).sub(px(0)).length());
  let reach = 0;
  for (const i of TIPS) reach += px(i).sub(center).length() / palmLen;
  reach /= TIPS.length;
  const pinchRatio = px(4).sub(px(8)).length() / palmLen;

  // Un point de la main dans la scène (bout des doigts…).
  const point = (i) => {
    const q = px(i);
    const d = Math.max(0.5, depth + (q.z - center.z) / sizePx);
    return new THREE.Vector3(((q.x - width / 2) * d) / focal, (-(q.y - height / 2) * d) / focal, -d);
  };
  const index = point(8);
  const thumb = point(4);

  return {
    position,
    quaternion,
    scale: 1,
    normal,
    reach,
    open: reach > 0.72,
    pinchRatio,
    index,
    thumb,
    pinch3d: index.clone().add(thumb).multiplyScalar(0.5),
    indexPx: { x: lm[8].x * width, y: lm[8].y * height },
    pinchPx: { x: ((lm[4].x + lm[8].x) / 2) * width, y: ((lm[4].y + lm[8].y) / 2) * height },
    center: { x: center.x, y: center.y },
    sizePx,
  };
}

/// Deux mains ouvertes : l'objet flotte entre les deux, d'autant plus grand
/// qu'elles sont écartées.
export function betweenHands(a, b) {
  const position = a.position.clone().add(b.position).multiplyScalar(0.5);
  const gap = a.position.distanceTo(b.position);
  const scale = Math.min(4, Math.max(0.5, gap * 0.55));
  const quaternion = basisFromUp(new THREE.Vector3(0, 1, 0), position);
  return { position: position.add(new THREE.Vector3(0, -0.45 * scale, 0)), quaternion, scale };
}

/// Pose du marqueur à partir de POSIT (js-aruco2). [rotation] 3×3 et
/// [translation] dans le repère de POSIT (x droite, y haut, z loin). On
/// choisit, parmi les deux solutions possibles, celle qui ressemble le plus
/// à la pose précédente ([previousUp]).
export function markerPose(candidates, previousUp) {
  let best = null;
  for (const c of candidates) {
    if (!c || !c.rotation || !c.translation) continue;
    const R = c.rotation;
    const t = c.translation;
    if (!(t[2] > 0)) continue;
    // Axes du marqueur dans la scène (z inversé).
    const ax = new THREE.Vector3(R[0][0], R[1][0], -R[2][0]);
    const ay = new THREE.Vector3(R[0][1], R[1][1], -R[2][1]);
    const az = new THREE.Vector3(R[0][2], R[1][2], -R[2][2]);
    const position = new THREE.Vector3(t[0], t[1], -t[2]);
    // Le « haut » est la face du marqueur tournée vers la caméra.
    const toCam = position.clone().negate().normalize();
    const up = az.dot(toCam) >= 0 ? az.clone() : az.clone().negate();
    // L'avant de l'objet regarde vers le bas du marqueur (vers toi).
    const forward = ay.clone().negate();
    const quaternion = basisFromUp(up, position, forward);
    const score = (previousUp ? up.dot(previousUp) : 0) - (c.error || 0) * 0.001;
    if (!best || score > best.score) best = { position, quaternion, scale: 1, up, ax, score };
  }
  return best;
}
