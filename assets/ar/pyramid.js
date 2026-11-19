// Pyramide holographique (« illusion de Pepper ») : une pyramide en
// plastique transparent posée pointe en bas au centre de l'écran. Chacune
// de ses 4 faces reflète la partie de l'écran qui est devant elle : l'objet
// apparaît alors dans l'air, à l'intérieur de la pyramide, visible à l'œil
// nu des 4 côtés.
//
// Géométrie : une face à 45° renvoie un point de l'écran situé à la
// distance d du centre à la hauteur d dans la pyramide. Chaque vue est donc
// dessinée « tête vers l'extérieur », et en miroir (la face est un miroir).
import * as THREE from './vendor/three.min.js';

export class PyramidView {
  constructor(renderer, scene) {
    this.renderer = renderer;
    this.scene = scene;
    this.targets = [0, 1, 2, 3].map(() => {
      const t = new THREE.WebGLRenderTarget(512, 512, { samples: 4 });
      t.texture.colorSpace = THREE.LinearSRGBColorSpace;
      return t;
    });
    this.cameras = [0, 1, 2, 3].map(() => new THREE.PerspectiveCamera(30, 1, 0.05, 100));
    // La « table de montage » : 4 carrés autour du centre, sur fond noir.
    this.comp = new THREE.Scene();
    this.compCam = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 10);
    this.compCam.position.z = 5;
    this.quads = this.targets.map((t, k) => {
      const mat = new THREE.MeshBasicMaterial({ map: t.texture, transparent: true, blending: THREE.AdditiveBlending, depthWrite: false });
      const quad = new THREE.Mesh(new THREE.PlaneGeometry(1, 1), mat);
      const arm = new THREE.Group();
      arm.rotation.z = (k * Math.PI) / 2; // 0 bas, 1 droite, 2 haut, 3 gauche
      arm.add(quad);
      this.comp.add(arm);
      return quad;
    });
    this.size = 0.42; // taille d'une vue (part du petit côté de l'écran)
    this.gap = 0.07; // carré du centre, sous la pointe de la pyramide
  }

  /// [width] × [height] en pixels CSS ; [scale] : taille réglée par la personne.
  layout(width, height, scale = 1) {
    const a = width / height;
    this.compCam.left = -a;
    this.compCam.right = a;
    this.compCam.top = 1;
    this.compCam.bottom = -1;
    this.compCam.updateProjectionMatrix();
    // Unités : 2 = le petit côté de l'écran.
    const unit = a >= 1 ? 2 : 2 * a;
    const s = this.size * unit * scale;
    const g = this.gap * unit * scale;
    for (const q of this.quads) {
      q.scale.set(s, -s, 1); // miroir : la face de la pyramide inverse l'image
      q.position.set(0, -(g / 2 + s / 2), 0); // tête vers l'extérieur
    }
  }

  /// Dessine les 4 vues de l'objet (centré en [target], ~[height] de haut).
  render(target, height = 1) {
    const r = this.renderer;
    const prevClear = r.getClearColor(new THREE.Color());
    const prevAlpha = r.getClearAlpha();
    const dist = (height * 0.62) / Math.tan(THREE.MathUtils.degToRad(15));
    for (let k = 0; k < 4; k++) {
      // Vue de face (bas de l'écran), puis de droite, de dos, de gauche :
      // chacun voit le côté de l'objet qui est en face de lui.
      const a = (k * Math.PI) / 2;
      const cam = this.cameras[k];
      cam.position.set(target.x + Math.sin(a) * dist, target.y + dist * 0.12, target.z + Math.cos(a) * dist);
      cam.lookAt(target);
      r.setRenderTarget(this.targets[k]);
      r.setClearColor(0x000000, 1);
      r.clear();
      r.render(this.scene, cam);
    }
    r.setRenderTarget(null);
    r.setClearColor(0x000000, 1);
    r.clear();
    r.render(this.comp, this.compCam);
    r.setClearColor(prevClear, prevAlpha);
  }
}

const cm = (mm) => `${String(mm / 10).replace('.', ',')} cm`;

/// Le gabarit d'une face de la pyramide (trapèze), en millimètres.
export function pyramidTemplate(top, height, base) {
  const w = base + 10;
  const h = height + 10;
  const x0 = 5;
  const y0 = 5;
  const off = (base - top) / 2;
  const pts = [
    [x0 + off, y0],
    [x0 + off + top, y0],
    [x0 + base, y0 + height],
    [x0, y0 + height],
  ]
    .map((p) => p.join(','))
    .join(' ');
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${w}mm" height="${h}mm" viewBox="0 0 ${w} ${h}">`
    + `<polygon points="${pts}" fill="none" stroke="#000" stroke-width="0.4" stroke-dasharray="2 1"/>`
    + `<text x="${w / 2}" y="${y0 + height * 0.7}" font-size="${Math.max(2.4, base / 22)}" text-anchor="middle" `
    + `font-family="sans-serif">${cm(top)} · ${cm(height)} · ${cm(base)}</text></svg>`;
}
