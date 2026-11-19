// Les objets 3D de la réalité augmentée, dessinés par le code (aucun
// fichier à télécharger). Chaque objet tient dans environ 1 × 1 × 1 unité,
// posé sur y = 0 (sa base), et s'anime dans update(t, dt).
import * as THREE from './vendor/three.min.js';

export const OBJECTS = [
  { id: 'dino', emoji: '🦖', label: 'T-rex' },
  { id: 'clicky', emoji: '🤖', label: 'Clicky' },
  { id: 'planete', emoji: '🪐', label: 'Planète' },
  { id: 'coeur', emoji: '❤️', label: 'Cœur' },
  { id: 'fusee', emoji: '🚀', label: 'Fusée' },
  { id: 'diamant', emoji: '💎', label: 'Diamant' },
  { id: 'systeme', emoji: '☀️', label: 'Système solaire' },
  { id: 'cube', emoji: '🧊', label: 'Cube magique' },
];

const std = (color, extra = {}) => new THREE.MeshStandardMaterial({ color, roughness: 0.45, metalness: 0.05, ...extra });

function canvasTexture(size, draw) {
  const c = document.createElement('canvas');
  c.width = c.height = size;
  draw(c.getContext('2d'), size);
  const t = new THREE.CanvasTexture(c);
  t.colorSpace = THREE.SRGBColorSpace;
  return t;
}

// ---------------------------------------------------------------- Clicky
function clicky() {
  const group = new THREE.Group();
  const body = new THREE.Group();
  group.add(body);
  // La flèche de Clicky (même dessin que dans Mon Hub), en relief.
  const pts = [
    [0, 0],
    [1, 0.42],
    [0.45, 0.55],
    [0.32, 1],
  ];
  const shape = new THREE.Shape();
  pts.forEach(([x, y], i) => (i ? shape.lineTo(x - 0.45, 0.5 - y) : shape.moveTo(x - 0.45, 0.5 - y)));
  shape.closePath();
  const geo = new THREE.ExtrudeGeometry(shape, {
    depth: 0.14,
    bevelEnabled: true,
    bevelThickness: 0.035,
    bevelSize: 0.03,
    bevelSegments: 4,
  });
  geo.translate(0, 0, -0.07);
  const blue = new THREE.MeshPhysicalMaterial({ color: 0x3b82f6, roughness: 0.25, clearcoat: 1, clearcoatRoughness: 0.15 });
  const white = new THREE.MeshPhysicalMaterial({ color: 0xffffff, roughness: 0.3, clearcoat: 0.6 });
  const arrow = new THREE.Mesh(geo, [blue, white]);
  arrow.scale.setScalar(0.78);
  body.add(arrow);

  // Les yeux, sur la face avant.
  const eyes = new THREE.Group();
  const eyeWhite = new THREE.MeshStandardMaterial({ color: 0xffffff, roughness: 0.2 });
  const pupil = new THREE.MeshStandardMaterial({ color: 0x0b1020, roughness: 0.1 });
  for (const x of [-0.075, 0.075]) {
    const e = new THREE.Mesh(new THREE.SphereGeometry(0.06, 24, 16), eyeWhite);
    e.scale.z = 0.5;
    e.position.set(x, 0, 0);
    const p = new THREE.Mesh(new THREE.SphereGeometry(0.032, 20, 12), pupil);
    p.position.set(0, 0, 0.026);
    e.add(p);
    eyes.add(e);
  }
  eyes.position.set(-0.03, 0.05, 0.1);
  body.add(eyes);

  // Halo bleu sous Clicky.
  const glow = new THREE.PointLight(0x60a5fa, 0.8, 1.5);
  glow.position.set(0, -0.2, 0.3);
  body.add(glow);

  let nextBlink = 2;
  return {
    group,
    update(t) {
      body.position.y = 0.55 + Math.sin(t * 2.1) * 0.05;
      body.rotation.y = Math.sin(t * 0.7) * 0.35;
      body.rotation.z = Math.sin(t * 1.3) * 0.06;
      const blink = t > nextBlink && t < nextBlink + 0.12;
      if (t > nextBlink + 0.12) nextBlink = t + 2 + Math.random() * 3;
      eyes.scale.y = blink ? 0.12 : 1;
    },
  };
}

// --------------------------------------------------------------- Planète
function planete() {
  const group = new THREE.Group();
  const holder = new THREE.Group();
  holder.position.y = 0.5;
  group.add(holder);
  const bands = canvasTexture(256, (g, s) => {
    const colors = ['#e9c891', '#d9a066', '#f2dcb0', '#c98a4b', '#ecd1a0', '#b8763f', '#f5e3bf', '#d7a46e'];
    let y = 0;
    while (y < s) {
      const h = 6 + Math.random() * 22;
      g.fillStyle = colors[Math.floor(Math.random() * colors.length)];
      g.fillRect(0, y, s, h + 1);
      y += h;
    }
    g.globalAlpha = 0.18;
    for (let i = 0; i < 60; i++) {
      g.fillStyle = Math.random() < 0.5 ? '#fff' : '#8a5a2b';
      g.fillRect(0, Math.random() * s, s, 1 + Math.random() * 2);
    }
  });
  const ball = new THREE.Mesh(new THREE.SphereGeometry(0.3, 64, 48), std(0xffffff, { map: bands, roughness: 0.8 }));
  holder.add(ball);
  const ringTex = canvasTexture(512, (g, s) => {
    const c = s / 2;
    for (let r = c * 0.6; r < c; r += 1) {
      const k = (r - c * 0.6) / (c * 0.4);
      const a = 0.25 + 0.6 * Math.abs(Math.sin(k * 18)) * (1 - k * 0.6);
      g.strokeStyle = `rgba(${220 - k * 40},${190 - k * 50},${150 - k * 60},${a})`;
      g.beginPath();
      g.arc(c, c, r, 0, Math.PI * 2);
      g.stroke();
    }
  });
  const ring = new THREE.Mesh(
    new THREE.RingGeometry(0.38, 0.62, 128),
    new THREE.MeshStandardMaterial({ map: ringTex, transparent: true, side: THREE.DoubleSide, roughness: 0.9, depthWrite: false }),
  );
  ring.rotation.x = -Math.PI / 2 + 0.42;
  holder.add(ring);
  const moon = new THREE.Mesh(new THREE.SphereGeometry(0.05, 24, 16), std(0xcfd3dc, { roughness: 0.95 }));
  holder.add(moon);
  return {
    group,
    update(t) {
      ball.rotation.y = t * 0.4;
      holder.rotation.z = 0.18;
      moon.position.set(Math.cos(t * 0.9) * 0.72, Math.sin(t * 0.9) * 0.12, Math.sin(t * 0.9) * 0.72);
    },
  };
}

// ----------------------------------------------------------------- Cœur
function coeur() {
  const group = new THREE.Group();
  const s = new THREE.Shape();
  s.moveTo(5, 5);
  s.bezierCurveTo(5, 5, 4, 0, 0, 0);
  s.bezierCurveTo(-6, 0, -6, 7, -6, 7);
  s.bezierCurveTo(-6, 11, -3, 15.4, 5, 19);
  s.bezierCurveTo(12, 15.4, 16, 11, 16, 7);
  s.bezierCurveTo(16, 7, 16, 0, 10, 0);
  s.bezierCurveTo(7, 0, 5, 5, 5, 5);
  const geo = new THREE.ExtrudeGeometry(s, { depth: 3, bevelEnabled: true, bevelThickness: 2.4, bevelSize: 2, bevelSegments: 8, curveSegments: 32 });
  geo.center();
  geo.rotateZ(Math.PI);
  geo.scale(0.034, 0.034, 0.034);
  const mat = new THREE.MeshPhysicalMaterial({ color: 0xe11d48, roughness: 0.22, clearcoat: 1, clearcoatRoughness: 0.08, sheen: 0.4 });
  const heart = new THREE.Mesh(geo, mat);
  heart.position.y = 0.52;
  group.add(heart);
  return {
    group,
    update(t) {
      const beat = (x) => Math.max(0, Math.sin(x)) ** 8;
      const k = (t * 1.25) % 1;
      const pulse = beat(k * Math.PI * 2) * 0.09 + beat((k - 0.18) * Math.PI * 2) * 0.05;
      heart.scale.setScalar(1 + pulse);
      heart.rotation.y = Math.sin(t * 0.8) * 0.6;
    },
  };
}

// ----------------------------------------------------------------- Fusée
function fusee() {
  const group = new THREE.Group();
  const rocket = new THREE.Group();
  group.add(rocket);
  const profile = [
    [0.0, 0.0],
    [0.1, 0.0],
    [0.13, 0.08],
    [0.14, 0.3],
    [0.13, 0.5],
    [0.1, 0.62],
    [0.0, 0.62],
  ].map(([x, y]) => new THREE.Vector2(x, y));
  const body = new THREE.Mesh(new THREE.LatheGeometry(profile, 48), std(0xf1f5f9, { metalness: 0.3, roughness: 0.3 }));
  rocket.add(body);
  const nose = new THREE.Mesh(new THREE.ConeGeometry(0.1, 0.22, 48), std(0xef4444, { roughness: 0.3 }));
  nose.position.y = 0.72;
  rocket.add(nose);
  const hublot = new THREE.Mesh(
    new THREE.CircleGeometry(0.05, 32),
    new THREE.MeshPhysicalMaterial({ color: 0x38bdf8, roughness: 0.05, metalness: 0.2, clearcoat: 1, emissive: 0x0c4a6e, emissiveIntensity: 0.4 }),
  );
  hublot.position.set(0, 0.4, 0.142);
  rocket.add(hublot);
  const rim = new THREE.Mesh(new THREE.TorusGeometry(0.055, 0.012, 12, 32), std(0x94a3b8, { metalness: 0.8, roughness: 0.25 }));
  rim.position.copy(hublot.position);
  rocket.add(rim);
  const finShape = new THREE.Shape();
  finShape.moveTo(0, 0);
  finShape.lineTo(0.13, -0.05);
  finShape.lineTo(0.13, 0.03);
  finShape.lineTo(0, 0.2);
  finShape.closePath();
  const finGeo = new THREE.ExtrudeGeometry(finShape, { depth: 0.02, bevelEnabled: false });
  finGeo.translate(0, 0, -0.01);
  for (let i = 0; i < 3; i++) {
    const fin = new THREE.Mesh(finGeo, std(0xef4444));
    const a = (i / 3) * Math.PI * 2 + Math.PI / 2;
    fin.position.set(Math.cos(a) * 0.11, 0.04, Math.sin(a) * 0.11);
    fin.rotation.y = -a;
    rocket.add(fin);
  }
  const flameMat = new THREE.MeshBasicMaterial({ color: 0xffb020, transparent: true, opacity: 0.9, blending: THREE.AdditiveBlending, depthWrite: false });
  const flame = new THREE.Mesh(new THREE.ConeGeometry(0.075, 0.28, 24, 1, true), flameMat);
  flame.rotation.x = Math.PI;
  flame.position.y = -0.14;
  rocket.add(flame);
  const core = new THREE.Mesh(new THREE.ConeGeometry(0.04, 0.16, 16, 1, true), new THREE.MeshBasicMaterial({ color: 0xffffff, transparent: true, opacity: 0.9, blending: THREE.AdditiveBlending, depthWrite: false }));
  core.rotation.x = Math.PI;
  core.position.y = -0.08;
  rocket.add(core);
  const light = new THREE.PointLight(0xff8a20, 1.2, 1.2);
  light.position.y = -0.15;
  rocket.add(light);
  return {
    group,
    update(t) {
      rocket.position.y = 0.3 + Math.sin(t * 1.6) * 0.04;
      rocket.rotation.z = Math.sin(t * 1.1) * 0.08;
      rocket.rotation.y = t * 0.6;
      const f = 0.85 + Math.random() * 0.3;
      flame.scale.set(1, f, 1);
      flame.position.y = -0.14 * f;
      light.intensity = 0.9 + Math.random() * 0.5;
    },
  };
}

// --------------------------------------------------------------- Diamant
function diamant() {
  const group = new THREE.Group();
  const gem = new THREE.Group();
  gem.position.y = 0.55;
  group.add(gem);
  const mat = new THREE.MeshPhysicalMaterial({
    color: 0xd8f3ff,
    roughness: 0,
    metalness: 0,
    transmission: 1,
    ior: 2.4,
    thickness: 0.4,
    envMapIntensity: 2.2,
    flatShading: true,
    specularIntensity: 1,
  });
  const crown = new THREE.Mesh(new THREE.CylinderGeometry(0.2, 0.32, 0.12, 8), mat);
  crown.position.y = 0.06;
  const pavilion = new THREE.Mesh(new THREE.ConeGeometry(0.32, 0.36, 8), mat);
  pavilion.rotation.x = Math.PI;
  pavilion.position.y = -0.18;
  gem.add(crown, pavilion);
  // Étincelles.
  const n = 40;
  const pos = new Float32Array(n * 3);
  for (let i = 0; i < n; i++) {
    const a = Math.random() * Math.PI * 2;
    const r = 0.35 + Math.random() * 0.25;
    pos.set([Math.cos(a) * r, (Math.random() - 0.5) * 0.6, Math.sin(a) * r], i * 3);
  }
  const g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.BufferAttribute(pos, 3));
  const star = canvasTexture(64, (c, s) => {
    const grd = c.createRadialGradient(s / 2, s / 2, 0, s / 2, s / 2, s / 2);
    grd.addColorStop(0, 'rgba(255,255,255,1)');
    grd.addColorStop(0.25, 'rgba(200,235,255,0.6)');
    grd.addColorStop(1, 'rgba(255,255,255,0)');
    c.fillStyle = grd;
    c.fillRect(0, 0, s, s);
  });
  const sparkMat = new THREE.PointsMaterial({ size: 0.06, map: star, transparent: true, blending: THREE.AdditiveBlending, depthWrite: false });
  const sparks = new THREE.Points(g, sparkMat);
  gem.add(sparks);
  return {
    group,
    update(t) {
      gem.rotation.y = t * 0.7;
      gem.position.y = 0.55 + Math.sin(t * 1.5) * 0.03;
      sparks.rotation.y = -t * 0.9;
      sparkMat.opacity = 0.5 + 0.5 * Math.abs(Math.sin(t * 3));
    },
  };
}

// ------------------------------------------------------- Système solaire
function systeme() {
  const group = new THREE.Group();
  const center = new THREE.Group();
  center.position.y = 0.32;
  group.add(center);
  const sun = new THREE.Mesh(new THREE.SphereGeometry(0.13, 48, 32), new THREE.MeshBasicMaterial({ color: 0xffc83d }));
  const corona = new THREE.Mesh(
    new THREE.SphereGeometry(0.17, 32, 24),
    new THREE.MeshBasicMaterial({ color: 0xff9a1f, transparent: true, opacity: 0.25, blending: THREE.AdditiveBlending, depthWrite: false }),
  );
  center.add(sun, corona);
  const light = new THREE.PointLight(0xfff1c1, 2.2, 3, 1);
  center.add(light);
  const planets = [
    { r: 0.22, size: 0.025, color: 0xb7a99a, speed: 1.6 },
    { r: 0.3, size: 0.04, color: 0xe8c07a, speed: 1.15 },
    { r: 0.4, size: 0.045, color: 0x3b82f6, speed: 0.9, moon: true },
    { r: 0.5, size: 0.035, color: 0xe2553b, speed: 0.7 },
  ].map((p, i) => {
    const orbit = new THREE.Mesh(
      new THREE.RingGeometry(p.r - 0.002, p.r + 0.002, 128),
      new THREE.MeshBasicMaterial({ color: 0xffffff, transparent: true, opacity: 0.25, side: THREE.DoubleSide, depthWrite: false }),
    );
    orbit.rotation.x = -Math.PI / 2;
    center.add(orbit);
    const mesh = new THREE.Mesh(new THREE.SphereGeometry(p.size, 32, 24), std(p.color, { roughness: 0.7 }));
    center.add(mesh);
    let moon = null;
    if (p.moon) {
      moon = new THREE.Mesh(new THREE.SphereGeometry(0.012, 16, 12), std(0xdddddd));
      mesh.add(moon);
    }
    return { ...p, mesh, moon, phase: i * 1.7 };
  });
  return {
    group,
    update(t) {
      sun.rotation.y = t * 0.3;
      corona.scale.setScalar(1 + Math.sin(t * 2) * 0.04);
      for (const p of planets) {
        const a = t * p.speed + p.phase;
        p.mesh.position.set(Math.cos(a) * p.r, 0, Math.sin(a) * p.r);
        p.mesh.rotation.y = t * 2;
        if (p.moon) p.moon.position.set(Math.cos(t * 4) * 0.08, 0, Math.sin(t * 4) * 0.08);
      }
    },
  };
}

// ---------------------------------------------------------- Cube magique
function cube() {
  const group = new THREE.Group();
  const root = new THREE.Group();
  root.position.y = 0.5;
  group.add(root);
  const size = 0.15;
  const gap = 0.004;
  const base = new THREE.RoundedBoxGeometry(size, size, size, 3, 0.025);
  const black = std(0x111111, { roughness: 0.35 });
  const faceColors = { px: 0xd32f2f, nx: 0xff8f00, py: 0xffffff, ny: 0xfdd835, pz: 0x2e7d32, nz: 0x1565c0 };
  const stickerGeo = new THREE.BoxGeometry(size * 0.82, size * 0.82, 0.006);
  const cubies = [];
  for (let x = -1; x <= 1; x++) {
    for (let y = -1; y <= 1; y++) {
      for (let z = -1; z <= 1; z++) {
        const c = new THREE.Mesh(base, black);
        c.position.set(x * (size + gap), y * (size + gap), z * (size + gap));
        const add = (color, px, py, pz, ry, rx) => {
          const s = new THREE.Mesh(stickerGeo, std(color, { roughness: 0.25 }));
          s.position.set(px, py, pz);
          s.rotation.set(rx, ry, 0);
          c.add(s);
        };
        const h = size / 2 + 0.002;
        if (x === 1) add(faceColors.px, h, 0, 0, Math.PI / 2, 0);
        if (x === -1) add(faceColors.nx, -h, 0, 0, -Math.PI / 2, 0);
        if (y === 1) add(faceColors.py, 0, h, 0, 0, -Math.PI / 2);
        if (y === -1) add(faceColors.ny, 0, -h, 0, 0, Math.PI / 2);
        if (z === 1) add(faceColors.pz, 0, 0, h, 0, 0);
        if (z === -1) add(faceColors.nz, 0, 0, -h, Math.PI, 0);
        root.add(c);
        cubies.push(c);
      }
    }
  }
  // Une couche tourne d'un quart de tour de temps en temps.
  const pivot = new THREE.Group();
  root.add(pivot);
  let turn = null;
  let nextTurn = 0.8;
  const axes = ['x', 'y', 'z'];
  return {
    group,
    update(t) {
      root.rotation.y = t * 0.45;
      root.rotation.x = 0.45 + Math.sin(t * 0.5) * 0.15;
      root.position.y = 0.5 + Math.sin(t * 1.4) * 0.03;
      if (!turn && t > nextTurn) {
        const axis = axes[Math.floor(Math.random() * 3)];
        const layer = Math.floor(Math.random() * 3) - 1;
        const step = size + gap;
        const members = cubies.filter((c) => Math.abs(c.position[axis] - layer * step) < step / 3);
        pivot.rotation.set(0, 0, 0);
        pivot.updateMatrixWorld();
        members.forEach((c) => pivot.attach(c));
        turn = { axis, start: t, dir: Math.random() < 0.5 ? 1 : -1, members };
      }
      if (turn) {
        const k = Math.min(1, (t - turn.start) / 0.45);
        const e = k < 0.5 ? 2 * k * k : 1 - (-2 * k + 2) ** 2 / 2;
        pivot.rotation[turn.axis] = turn.dir * e * (Math.PI / 2);
        if (k >= 1) {
          pivot.updateMatrixWorld();
          turn.members.forEach((c) => {
            root.attach(c);
            const step = size + gap;
            c.position.set(Math.round(c.position.x / step) * step, Math.round(c.position.y / step) * step, Math.round(c.position.z / step) * step);
          });
          turn = null;
          nextTurn = t + 0.5 + Math.random() * 0.8;
        }
      }
    },
  };
}

// ---------------------------------------------------------------- T-rex
// Un tube dont l'épaisseur varie le long d'une courbe (queue → corps → cou).
function sweptBody(points, radius, lateral = 0.85, vertical = 1.15, segments = 64, radial = 14) {
  const curve = new THREE.CatmullRomCurve3(points.map(([x, y]) => new THREE.Vector3(x, y, 0)));
  const geo = new THREE.TubeGeometry(curve, segments, 1, radial, false);
  const p = geo.attributes.position;
  const v = new THREE.Vector3();
  for (let i = 0; i <= segments; i++) {
    const u = i / segments;
    const c = curve.getPointAt(u);
    const r = radius(u);
    for (let j = 0; j <= radial; j++) {
      const k = i * (radial + 1) + j;
      v.fromBufferAttribute(p, k).sub(c);
      v.set(v.x * r * vertical, v.y * r * vertical, v.z * r * lateral);
      p.setXYZ(k, c.x + v.x, c.y + v.y, c.z + v.z);
    }
  }
  geo.computeVertexNormals();
  return geo;
}

// Un membre (cylindre effilé) entre deux points.
function limb(a, b, r1, r2, mat) {
  const A = new THREE.Vector3(...a);
  const B = new THREE.Vector3(...b);
  const len = A.distanceTo(B);
  const m = new THREE.Mesh(new THREE.CylinderGeometry(r2, r1, len, 10, 2), mat);
  m.position.copy(A).add(B).multiplyScalar(0.5);
  m.quaternion.setFromUnitVectors(new THREE.Vector3(0, 1, 0), B.clone().sub(A).normalize());
  return m;
}

function dino() {
  const group = new THREE.Group();
  const rex = new THREE.Group();
  rex.rotation.y = 0.5;
  group.add(rex);
  const skin = std(0x5b7f3a, { roughness: 0.75 });
  const belly = std(0xc9b98a, { roughness: 0.8 });
  const smooth = (a, b, x) => {
    const t = Math.min(1, Math.max(0, (x - a) / (b - a)));
    return t * t * (3 - 2 * t);
  };

  // Corps et cou.
  const body = new THREE.Mesh(
    sweptBody(
      [[0.05, 0.56], [-0.12, 0.6], [-0.27, 0.62], [-0.38, 0.7], [-0.45, 0.8]],
      (u) => 0.15 - 0.07 * smooth(0.45, 1, u) + 0.02 * Math.sin(u * Math.PI),
    ),
    skin,
  );
  rex.add(body);

  // La queue, à part pour qu'elle bouge.
  const tailPivot = new THREE.Group();
  tailPivot.position.set(0.05, 0.56, 0);
  rex.add(tailPivot);
  const tail = new THREE.Mesh(
    sweptBody([[0, 0], [0.22, -0.02], [0.45, -0.06], [0.68, -0.12], [0.9, -0.2]], (u) => 0.15 * (1 - u) ** 1.25 + 0.004, 0.8, 1.15, 48, 12),
    skin,
  );
  tailPivot.add(tail);

  // La tête et la mâchoire.
  const head = new THREE.Group();
  head.position.set(-0.47, 0.84, 0);
  rex.add(head);
  const skullGeo = new THREE.BoxGeometry(0.3, 0.13, 0.15, 6, 3, 3);
  const sp = skullGeo.attributes.position;
  for (let i = 0; i < sp.count; i++) {
    const x = sp.getX(i);
    const k = 1 - Math.max(0, -x - 0.02) * 1.6; // museau plus fin
    sp.setY(i, sp.getY(i) * k + (sp.getY(i) > 0 ? 0.015 * Math.cos(x * 9) : 0));
    sp.setZ(i, sp.getZ(i) * (0.75 + 0.25 * k));
  }
  skullGeo.computeVertexNormals();
  const skull = new THREE.Mesh(skullGeo, skin);
  skull.position.set(-0.11, 0.02, 0);
  head.add(skull);
  const jawPivot = new THREE.Group();
  jawPivot.position.set(0.02, -0.035, 0);
  head.add(jawPivot);
  const jaw = new THREE.Mesh(new THREE.BoxGeometry(0.26, 0.045, 0.12, 5, 1, 2), belly);
  jaw.position.set(-0.13, -0.02, 0);
  jawPivot.add(jaw);
  const teethMat = std(0xf5f0e0, { roughness: 0.4 });
  for (let i = 0; i < 6; i++) {
    for (const z of [-0.05, 0.05]) {
      const tooth = new THREE.Mesh(new THREE.ConeGeometry(0.008, 0.025, 5), teethMat);
      tooth.rotation.x = Math.PI;
      tooth.position.set(-0.135 + i * 0.024, -0.048, z * 0.85);
      skull.add(tooth);
    }
  }
  const eyeMat = std(0xffc21a, { emissive: 0x7a4a00, emissiveIntensity: 0.6, roughness: 0.2 });
  for (const z of [-0.07, 0.07]) {
    const eye = new THREE.Mesh(new THREE.SphereGeometry(0.016, 12, 8), eyeMat);
    eye.position.set(0.07, 0.045, z * 0.95);
    skull.add(eye);
  }

  // Les pattes (puissantes) et les petits bras.
  const legs = [];
  for (const z of [-0.09, 0.09]) {
    const leg = new THREE.Group();
    leg.position.set(0.0, 0.55, z);
    leg.add(limb([0, 0, 0], [0.07, -0.24, 0], 0.085, 0.06, skin));
    leg.add(limb([0.07, -0.24, 0], [-0.01, -0.45, 0], 0.05, 0.035, skin));
    leg.add(limb([-0.01, -0.45, 0], [-0.03, -0.53, 0], 0.035, 0.03, skin));
    const foot = new THREE.Mesh(new THREE.BoxGeometry(0.15, 0.03, 0.08, 3, 1, 2), skin);
    foot.position.set(-0.08, -0.535, 0);
    leg.add(foot);
    rex.add(leg);
    legs.push(leg);
    const arm = new THREE.Group();
    arm.position.set(-0.3, 0.6, z * 1.1);
    arm.add(limb([0, 0, 0], [-0.04, -0.07, 0], 0.018, 0.014, skin));
    arm.add(limb([-0.04, -0.07, 0], [-0.08, -0.06, 0], 0.014, 0.01, skin));
    rex.add(arm);
  }

  let roarAt = 3;
  return {
    group,
    update(t) {
      const breath = Math.sin(t * 2.2);
      body.scale.set(1, 1 + breath * 0.02, 1 + breath * 0.025);
      tailPivot.rotation.y = Math.sin(t * 1.3) * 0.22;
      tailPivot.rotation.z = Math.sin(t * 0.9) * 0.05;
      // Rugissement de temps en temps.
      const r = t - roarAt;
      const roar = r > 0 && r < 1.4 ? Math.sin((r / 1.4) * Math.PI) : 0;
      if (r > 1.4) roarAt = t + 4 + Math.random() * 4;
      jawPivot.rotation.z = 0.05 + roar * 0.55 + Math.max(0, Math.sin(t * 2.2)) * 0.04;
      head.rotation.z = -roar * 0.25 + Math.sin(t * 0.8) * 0.04;
      head.rotation.y = Math.sin(t * 0.5) * 0.35 * (1 - roar);
      legs.forEach((l, i) => (l.rotation.z = Math.sin(t * 1.1 + i * Math.PI) * 0.03));
    },
  };
}

// ------------------------------------------- Objet inventé (par l'IA)
// La « recette » ne contient que des données (formes, couleurs, positions) :
// jamais de code. Elle est vérifiée dans Mon Hub puis encore ici.
const SHAPES = {
  sphere: () => new THREE.SphereGeometry(0.5, 32, 24),
  boite: () => new THREE.RoundedBoxGeometry(1, 1, 1, 2, 0.06),
  cylindre: () => new THREE.CylinderGeometry(0.5, 0.5, 1, 32),
  cone: () => new THREE.ConeGeometry(0.5, 1, 32),
  tore: () => new THREE.TorusGeometry(0.4, 0.12, 16, 48),
  capsule: () => new THREE.CapsuleGeometry(0.3, 0.4, 8, 16),
};

const num = (v, d, lo, hi) => {
  const n = Number(v);
  return Number.isFinite(n) ? Math.min(hi, Math.max(lo, n)) : d;
};
const vec3 = (v, d, lo, hi) => (Array.isArray(v) ? [0, 1, 2].map((i) => num(v[i], d, lo, hi)) : [d, d, d]);

function material(kind, color) {
  switch (kind) {
    case 'metal':
      return std(color, { metalness: 0.9, roughness: 0.25 });
    case 'brillant':
      return new THREE.MeshPhysicalMaterial({ color, roughness: 0.2, clearcoat: 1 });
    case 'verre':
      return new THREE.MeshPhysicalMaterial({ color, roughness: 0.05, transmission: 0.9, thickness: 0.3, ior: 1.5 });
    case 'lumineux':
      return new THREE.MeshStandardMaterial({ color, emissive: color, emissiveIntensity: 1.2 });
    default:
      return std(color, { roughness: 0.6 });
  }
}

export function buildCustom(recipe) {
  const group = new THREE.Group();
  const model = new THREE.Group();
  const pieces = Array.isArray(recipe?.pieces) ? recipe.pieces.slice(0, 80) : [];
  const geos = {};
  for (const p of pieces) {
    const make = SHAPES[p?.forme];
    if (!make) continue;
    const color = /^#[0-9a-fA-F]{6}$/.test(p.couleur || '') ? p.couleur : '#cccccc';
    const mesh = new THREE.Mesh((geos[p.forme] ||= make()), material(p.matiere, new THREE.Color(color)));
    mesh.position.fromArray(vec3(p.pos, 0, -10, 10));
    mesh.scale.fromArray(vec3(p.taille, 0.2, 0.005, 10));
    const r = vec3(p.rot, 0, -360, 360).map((d) => (d * Math.PI) / 180);
    mesh.rotation.set(r[0], r[1], r[2]);
    model.add(mesh);
  }
  // On le remet à la bonne taille, posé sur sa base, quelle que soit
  // l'échelle choisie par l'IA.
  const box = new THREE.Box3().setFromObject(model);
  if (!box.isEmpty()) {
    const size = box.getSize(new THREE.Vector3());
    const k = 0.95 / Math.max(size.x, size.y, size.z, 1e-3);
    model.scale.setScalar(k);
    const c = box.getCenter(new THREE.Vector3());
    model.position.set(-c.x * k, -box.min.y * k + 0.05, -c.z * k);
  }
  group.add(model);
  const spin = recipe?.tourne !== false;
  return {
    group,
    update(t) {
      if (spin) group.rotation.y = t * 0.5;
      group.position.y = Math.sin(t * 1.5) * 0.02;
    },
  };
}

const BUILDERS = { dino, clicky, planete, coeur, fusee, diamant, systeme, cube };

export function buildObject(id) {
  return (BUILDERS[id] || dino)();
}
