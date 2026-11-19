// Style « hologramme » : fils de lumière cyan, reflets sur les bords,
// lignes de balayage, et un socle qui projette l'objet (faisceau, rayons,
// particules), comme dans les films.
import * as THREE from './vendor/three.min.js';

export const HOLO_COLOR = new THREE.Color(0x3ff3ff);
const uniforms = { uTime: { value: 0 }, uColor: { value: HOLO_COLOR }, uOpacity: { value: 1 } };

/// Le corps translucide : plus lumineux sur les bords (comme du verre éclairé).
export const holoSkin = new THREE.ShaderMaterial({
  uniforms,
  transparent: true,
  depthWrite: false,
  side: THREE.DoubleSide,
  blending: THREE.AdditiveBlending,
  vertexShader: /* glsl */ `
    varying vec3 vN;
    varying vec3 vV;
    void main() {
      vec4 mv = modelViewMatrix * vec4(position, 1.0);
      vN = normalize(normalMatrix * normal);
      vV = normalize(-mv.xyz);
      gl_Position = projectionMatrix * mv;
    }`,
  fragmentShader: /* glsl */ `
    uniform vec3 uColor;
    uniform float uTime;
    uniform float uOpacity;
    varying vec3 vN;
    varying vec3 vV;
    void main() {
      float rim = pow(1.0 - abs(dot(normalize(vN), normalize(vV))), 2.2);
      float scan = 0.72 + 0.28 * sin(gl_FragCoord.y * 0.9 - uTime * 9.0);
      float band = smoothstep(0.0, 0.02, abs(fract(gl_FragCoord.y * 0.004 - uTime * 0.35) - 0.5) - 0.47);
      float flicker = 0.93 + 0.07 * sin(uTime * 41.0) * sin(uTime * 13.0);
      float a = (0.05 + rim * 0.75 + band * 0.25) * scan * flicker * uOpacity;
      gl_FragColor = vec4(uColor * (0.7 + rim * 1.3), a);
    }`,
});

/// Les fils (le maillage).
export const holoWire = new THREE.LineBasicMaterial({
  color: HOLO_COLOR,
  transparent: true,
  opacity: 0.55,
  depthWrite: false,
  blending: THREE.AdditiveBlending,
});

export function tickHolo(t) {
  uniforms.uTime.value = t;
}

/// Passe un objet en hologramme ([on] = true) ou en couleurs réelles.
export function setHolo(root, on) {
  root.traverse((o) => {
    if (o.userData.holoPart) return;
    if (o.isMesh) {
      if (!o.userData.real) o.userData.real = o.material;
      if (on) {
        o.material = holoSkin;
        if (!o.userData.wire) {
          const w = new THREE.LineSegments(new THREE.WireframeGeometry(o.geometry), holoWire);
          w.userData.holoPart = true;
          w.raycast = () => {};
          o.add(w);
          o.userData.wire = w;
        }
        o.userData.wire.visible = true;
      } else {
        o.material = o.userData.real;
        if (o.userData.wire) o.userData.wire.visible = false;
      }
    } else if (o.isPoints) {
      o.material.color?.set(on ? HOLO_COLOR : 0xffffff);
    } else if (o.isLight) {
      if (o.userData.realColor === undefined) o.userData.realColor = o.color.getHex();
      o.color.set(on ? HOLO_COLOR : o.userData.realColor);
    }
  });
}

function glowTexture(inner = 'rgba(160,255,255,1)') {
  const c = document.createElement('canvas');
  c.width = c.height = 128;
  const g = c.getContext('2d');
  const grd = g.createRadialGradient(64, 64, 0, 64, 64, 64);
  grd.addColorStop(0, inner);
  grd.addColorStop(0.3, 'rgba(63,243,255,0.45)');
  grd.addColorStop(1, 'rgba(63,243,255,0)');
  g.fillStyle = grd;
  g.fillRect(0, 0, 128, 128);
  return new THREE.CanvasTexture(c);
}

/// Le socle projecteur : hexagone lumineux, faisceau, rayons et particules.
export function makeProjector() {
  const group = new THREE.Group();
  const add = (o) => {
    o.userData.holoPart = true;
    group.add(o);
    return o;
  };
  const glow = glowTexture();
  const additive = { transparent: true, depthWrite: false, blending: THREE.AdditiveBlending };

  // Hexagones au sol.
  const hex = (r, opacity) => {
    const pts = [];
    for (let i = 0; i <= 6; i++) {
      const a = (i / 6) * Math.PI * 2 + Math.PI / 6;
      pts.push(new THREE.Vector3(Math.cos(a) * r, 0.004, Math.sin(a) * r));
    }
    return add(new THREE.Line(new THREE.BufferGeometry().setFromPoints(pts), new THREE.LineBasicMaterial({ color: HOLO_COLOR, opacity, ...additive })));
  };
  const outer = hex(0.62, 0.95);
  const inner = hex(0.5, 0.45);
  const floor = add(
    new THREE.Mesh(new THREE.CircleGeometry(0.62, 6, Math.PI / 6), new THREE.MeshBasicMaterial({ color: 0x0b6b78, opacity: 0.35, ...additive })),
  );
  floor.rotation.x = -Math.PI / 2;
  floor.position.y = 0.002;
  const spot = add(new THREE.Mesh(new THREE.PlaneGeometry(0.5, 0.5), new THREE.MeshBasicMaterial({ map: glow, ...additive })));
  spot.rotation.x = -Math.PI / 2;
  spot.position.y = 0.006;

  // Le faisceau : un cône ouvert qui s'efface vers le haut.
  const beamMat = new THREE.ShaderMaterial({
    uniforms: { uTime: uniforms.uTime, uColor: uniforms.uColor },
    ...additive,
    side: THREE.DoubleSide,
    vertexShader: `varying vec2 vUv; void main(){ vUv = uv; gl_Position = projectionMatrix * modelViewMatrix * vec4(position,1.0); }`,
    fragmentShader: `
      uniform float uTime; uniform vec3 uColor; varying vec2 vUv;
      void main(){
        float fade = pow(1.0 - vUv.y, 1.6);
        float streak = 0.55 + 0.45 * sin(vUv.x * 60.0 + uTime * 1.5) * sin(vUv.x * 23.0 - uTime);
        gl_FragColor = vec4(uColor, fade * streak * 0.22);
      }`,
  });
  const beam = add(new THREE.Mesh(new THREE.CylinderGeometry(0.62, 0.05, 1.15, 48, 1, true), beamMat));
  beam.position.y = 0.575;

  // Rayons qui partent du socle.
  const rays = new THREE.Group();
  const rayMat = new THREE.MeshBasicMaterial({ color: HOLO_COLOR, opacity: 0.16, side: THREE.DoubleSide, ...additive });
  for (let i = 0; i < 9; i++) {
    const len = 0.9 + Math.random() * 0.8;
    const geo = new THREE.BufferGeometry().setFromPoints([
      new THREE.Vector3(0, 0, 0),
      new THREE.Vector3(-0.02, len, 0),
      new THREE.Vector3(0.02, len, 0),
    ]);
    const ray = new THREE.Mesh(geo, rayMat);
    ray.rotation.set((Math.random() - 0.5) * 1.2, (i / 9) * Math.PI * 2, (Math.random() - 0.5) * 1.2);
    ray.userData.holoPart = true;
    rays.add(ray);
  }
  add(rays);

  // Particules qui montent.
  const n = 70;
  const pos = new Float32Array(n * 3);
  const seeds = [];
  for (let i = 0; i < n; i++) seeds.push({ a: Math.random() * Math.PI * 2, r: Math.random(), y: Math.random(), s: 0.15 + Math.random() * 0.35 });
  const pgeo = new THREE.BufferGeometry();
  pgeo.setAttribute('position', new THREE.BufferAttribute(pos, 3));
  const dots = add(new THREE.Points(pgeo, new THREE.PointsMaterial({ size: 0.035, map: glow, color: HOLO_COLOR, ...additive })));

  return {
    group,
    update(t, dt) {
      outer.rotation.y = t * 0.25;
      inner.rotation.y = -t * 0.4;
      spot.material.opacity = 0.75 + Math.sin(t * 3) * 0.2;
      rays.rotation.y = t * 0.08;
      rayMat.opacity = 0.12 + Math.sin(t * 1.7) * 0.05;
      for (let i = 0; i < n; i++) {
        const s = seeds[i];
        s.y += s.s * dt;
        if (s.y > 1) s.y -= 1;
        const r = (0.08 + 0.5 * s.y) * s.r;
        pos[i * 3] = Math.cos(s.a + t * 0.3) * r;
        pos[i * 3 + 1] = s.y * 1.1;
        pos[i * 3 + 2] = Math.sin(s.a + t * 0.3) * r;
      }
      pgeo.attributes.position.needsUpdate = true;
    },
  };
}

/// Les points lumineux au bout des doigts (on voit que la caméra les suit).
export function makeFingertip() {
  const mat = new THREE.SpriteMaterial({ map: glowTexture('rgba(255,255,255,1)'), color: HOLO_COLOR, transparent: true, depthWrite: false, depthTest: false, blending: THREE.AdditiveBlending });
  const s = new THREE.Sprite(mat);
  s.renderOrder = 10;
  return s;
}
