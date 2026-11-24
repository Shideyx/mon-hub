import 'package:flutter/foundation.dart';

import 'module_store.dart';

/// Le flou de la caméra **dans les appels passés par Mon Hub** (le Discord
/// intégré) : l'image de ta caméra passe par Mon Hub avant de partir, et ton
/// visage (ou toute l'image) est flouté. Les autres voient le flou, jamais
/// l'image nette.
///
/// Quatre façons :
/// * `fond` : l'arrière-plan flou, ton visage (et tes épaules) restent nets ;
///   visage pas trouvé : tout flou ;
/// * `visage` : seulement ton visage caché (Windows le repère) ; si ton
///   visage n'est pas trouvé, **toute** l'image est floue (jamais de raté net) ;
/// * `tout` : toute l'image floue (on devine une personne, rien de plus) ;
/// * `non` : l'image normale.
///
/// Ce flou ne protège pas d'un pirate (il lirait la caméra avant Mon Hub) :
/// contre ça, c'est la caméra coupée (mode caméra privée, `CameraGuard`).
class CamBlur extends ChangeNotifier {
  CamBlur._();
  static final instance = CamBlur._();

  static const modes = ['non', 'fond', 'visage', 'tout'];
  static const _kMode = 'app.cam.flou';

  /// L'argument du navigateur intégré (WebView2) qui allume la détection des
  /// visages de Windows (`FaceDetector`). Le même pour tous les programmes
  /// de Mon Hub, sinon WebView2 refuse de s'ouvrir.
  static const browserArgs = '--enable-blink-features=ShapeDetection';

  /// Ajoute [browserArgs] aux arguments déjà demandés (sans doublon).
  static String withArgs(String? current) {
    final c = (current ?? '').trim();
    if (c.contains('ShapeDetection')) return c;
    return c.isEmpty ? browserArgs : '$c $browserArgs';
  }

  /// La façon choisie (gardée pour les prochains appels).
  String get mode {
    try {
      final m = ModuleStore.global.getString(_kMode);
      return modes.contains(m) ? m! : 'non';
    } catch (_) {
      return 'non';
    }
  }

  /// Change la façon ; [apply] l'envoie tout de suite à l'appel en cours.
  Future<void> setMode(String m) async {
    if (!modes.contains(m)) return;
    try {
      await ModuleStore.global.setString(_kMode, m);
    } catch (_) {}
    notifyListeners();
    await apply?.call(liveScript(m));
  }

  /// Envoie un script à la page de l'appel (branché par le Discord intégré).
  Future<void> Function(String js)? apply;

  /// Ce qui est vu : la détection des visages marche (null = pas encore su).
  bool? faceDetection;

  static String label(String m) => switch (m) {
    'fond' => 'Arrière-plan flou',
    'visage' => 'Visage flouté',
    'tout' => 'Tout flou',
    _ => 'Sans flou',
  };

  static String say(String m, {bool? faces}) => switch (m) {
    'fond' =>
      faces == false
          ? 'Flou activé. Ce PC ne sait pas repérer les visages, alors toute l\'image est floue.'
          : 'Ton arrière-plan est flou, ton visage reste net. Si je ne te trouve pas, toute l\'image devient floue.',
    'visage' =>
      faces == false
          ? 'Flou activé. Ce PC ne sait pas repérer les visages, alors toute l\'image est floue.'
          : 'Ton visage est flouté. Si je ne le trouve pas, toute l\'image devient floue.',
    'tout' => 'Toute ton image est floue : on devine une personne, rien de plus.',
    _ => 'Ta caméra n\'est plus floutée.',
  };

  /// Lit « floute mon visage », « floute tout », « enlève le flou ».
  static String? modeFrom(String text) {
    final t = text
        .toLowerCase()
        .replaceAll(RegExp('[éèê]'), 'e')
        .replaceAll(RegExp(r"[’'?!.,]"), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (RegExp(
      r'^(?:enleve|retire|arrete|coupe|desactive|stop|plus de)\s?(?:le |mon )?flou(?: de (?:ma )?(?:camera|webcam|mon visage))?$',
    ).hasMatch(t)) {
      return 'non';
    }
    if (RegExp(
      r'^(?:floute|flouter|rends? flou|cache|masque) (?:moi |mon |le )?(?:visage|tete|figure|tronche)(?: (?:a|pendant) (?:la camera|l appel|mon appel|la webcam))?$',
    ).hasMatch(t)) {
      return 'visage';
    }
    if (RegExp(r'^(?:floute|rends? flou) (?:tout|toute (?:ma |l )?image|toute la camera|ma camera en entier)$')
        .hasMatch(t)) {
      return 'tout';
    }
    if (RegExp(
      r'^(?:floute|flouter|rends? flou|cache) (?:moi )?(?:mon |l |le |la )?(?:arriere(?: |-)?plan|fond|decor|chambre|piece|derriere moi)'
      r'(?: (?:a|pendant) (?:la camera|l appel|mon appel|la webcam))?$',
    ).hasMatch(t)) {
      return 'fond';
    }
    return null;
  }

  /// Change la façon en direct dans la page de l'appel.
  static String liveScript(String m) => "window.__monhubFlou = '${modes.contains(m) ? m : 'non'}';";

  /// Le script mis dans la page **avant** Discord : chaque caméra demandée
  /// passe par un filtre image par image (MediaStreamTrackProcessor →
  /// OffscreenCanvas → MediaStreamTrackGenerator). Le filtre est toujours
  /// branché (même sans flou) pour pouvoir l'allumer en plein appel.
  static String script(String m) => _script.replaceFirst('%MODE%', modes.contains(m) ? m : 'non');

  static const _script = r'''
(() => {
  if (window.__monhubFlouHook) return;
  window.__monhubFlouHook = true;
  if (window.__monhubFlou === undefined) window.__monhubFlou = '%MODE%';
  const md = navigator.mediaDevices;
  if (!md || !md.getUserMedia) return;
  const orig = md.getUserMedia.bind(md);
  let detector = null;
  try {
    if ('FaceDetector' in window) detector = new FaceDetector({ fastMode: true, maxDetectedFaces: 4 });
  } catch (e) {}
  const state = { visage: !!detector, pistes: 0, erreur: '' };
  window.__monhubFlouEtat = () => JSON.stringify({ mode: window.__monhubFlou, ...state });

  function makeFilter() {
    let canvas = null, ctx = null, small = null, sctx = null;
    let faces = [], facesAt = -1e9, busy = false, lastDetect = -1e9;
    return (src, w, h) => {
      const mode = window.__monhubFlou;
      if (!canvas || canvas.width !== w || canvas.height !== h) {
        canvas = new OffscreenCanvas(w, h);
        ctx = canvas.getContext('2d');
        small = new OffscreenCanvas(Math.max(8, Math.round(w / 28)), Math.max(6, Math.round(h / 28)));
        sctx = small.getContext('2d');
      }
      ctx.drawImage(src, 0, 0, w, h);
      if (mode !== 'visage' && mode !== 'tout' && mode !== 'fond') return canvas;
      const now = performance.now();
      const findFaces = mode === 'visage' || mode === 'fond';
      if (findFaces && detector && !busy && now - lastDetect > 120) {
        busy = true;
        lastDetect = now;
        createImageBitmap(canvas)
          .then((bm) =>
            detector.detect(bm).then(
              (r) => { faces = r.map((f) => f.boundingBox); facesAt = performance.now(); bm.close(); },
              () => { faces = []; facesAt = -1e9; state.visage = false; bm.close(); },
            ),
          )
          .catch(() => {})
          .finally(() => { busy = false; });
      }
      sctx.imageSmoothingEnabled = true;
      sctx.drawImage(canvas, 0, 0, small.width, small.height);
      ctx.imageSmoothingEnabled = true;
      // Arrière-plan : on garde le dernier visage un peu plus longtemps (pas de
      // clignotement quand tu bouges la tête).
      const keep = mode === 'fond' ? 1500 : 700;
      const fresh = findFaces && detector && faces.length > 0 && now - facesAt < keep;
      if (!fresh) {
        // « tout », ou visage pas trouvé : TOUTE l'image floue (jamais net par erreur).
        ctx.drawImage(small, 0, 0, w, h);
        return canvas;
      }
      if (mode === 'fond') {
        // Tout flou, puis ta tête et tes épaules redessinées nettes.
        ctx.drawImage(small, 0, 0, w, h);
        for (const b of faces) {
          const cx = b.x + b.width / 2, cy = b.y + b.height * 0.95;
          const rx = b.width * 1.45, ry = b.height * 1.9;
          ctx.save();
          ctx.beginPath();
          ctx.ellipse(cx, cy, rx, ry, 0, 0, Math.PI * 2);
          ctx.clip();
          ctx.drawImage(src, 0, 0, w, h);
          ctx.restore();
        }
        return canvas;
      }
      for (const b of faces) {
        const cx = b.x + b.width / 2, cy = b.y + b.height / 2;
        const rx = b.width * 0.85, ry = b.height * 1.0;
        ctx.save();
        ctx.beginPath();
        ctx.ellipse(cx, cy, rx, ry, 0, 0, Math.PI * 2);
        ctx.clip();
        ctx.drawImage(small, 0, 0, w, h);
        ctx.restore();
      }
      return canvas;
    };
  }

  function wrap(track) {
    const filter = makeFilter();
    let out;
    if ('MediaStreamTrackProcessor' in window && 'MediaStreamTrackGenerator' in window) {
      const proc = new MediaStreamTrackProcessor({ track });
      const gen = new MediaStreamTrackGenerator({ kind: 'video' });
      const ts = new TransformStream({
        transform(frame, ctl) {
          try {
            const c = filter(frame, frame.displayWidth, frame.displayHeight);
            const f = new VideoFrame(c, { timestamp: frame.timestamp });
            frame.close();
            ctl.enqueue(f);
          } catch (e) {
            state.erreur = String(e);
            frame.close();
          }
        },
      });
      proc.readable.pipeThrough(ts).pipeTo(gen.writable).catch(() => {});
      out = gen;
    } else {
      // Ancien moteur : une vidéo cachée + une toile filmée.
      const v = document.createElement('video');
      v.muted = true;
      v.playsInline = true;
      v.srcObject = new MediaStream([track]);
      v.play().catch(() => {});
      const s = track.getSettings();
      const view = document.createElement('canvas');
      view.width = s.width || 640;
      view.height = s.height || 480;
      const vctx = view.getContext('2d');
      const timer = setInterval(() => {
        if (v.readyState < 2) return;
        vctx.drawImage(filter(v, view.width, view.height), 0, 0);
      }, 1000 / (s.frameRate || 24));
      out = view.captureStream(s.frameRate || 24).getVideoTracks()[0];
      track.addEventListener('ended', () => clearInterval(timer));
    }
    const stopOut = out.stop.bind(out);
    out.stop = () => { try { track.stop(); } catch (e) {} stopOut(); };
    track.addEventListener('ended', () => { try { stopOut(); } catch (e) {} });
    for (const k of ['getSettings', 'getCapabilities', 'getConstraints', 'applyConstraints']) {
      if (typeof track[k] === 'function') out[k] = (...a) => track[k](...a);
    }
    try { Object.defineProperty(out, 'label', { value: track.label }); } catch (e) {}
    state.pistes++;
    return out;
  }

  md.getUserMedia = async function (c) {
    const s = await orig(c);
    if (!c || !c.video) return s;
    try {
      const outStream = new MediaStream();
      for (const t of s.getTracks()) outStream.addTrack(t.kind === 'video' ? wrap(t) : t);
      return outStream;
    } catch (e) {
      state.erreur = String(e);
      // Flou demandé mais impossible : pas d'image plutôt qu'une image nette.
      if (window.__monhubFlou === 'visage' || window.__monhubFlou === 'tout' || window.__monhubFlou === 'fond') {
        s.getVideoTracks().forEach((t) => t.stop());
        throw new DOMException('Flou impossible', 'NotReadableError');
      }
      return s;
    }
  };
})();
''';
}
