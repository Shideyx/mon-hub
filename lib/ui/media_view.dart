import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_ui/material_ui.dart';

import 'web_login.dart';
import 'widgets.dart';

/// Une photo ou une vidéo (reel, vidéo envoyée en message…).
class MediaItem {
  const MediaItem({this.image, this.video});
  final String? image;
  final String? video;

  bool get isVideo => video != null && video!.isNotEmpty;

  @override
  bool operator ==(Object other) => other is MediaItem && other.image == image && other.video == video;

  @override
  int get hashCode => Object.hash(image, video);
}

/// Une vidéo jouée par le navigateur intégré (WebView2 d'Edge lit le MP4
/// d'Instagram et de Discord) : pas de lecteur en plus à installer.
class WebVideo extends StatelessWidget {
  const WebVideo({
    super.key,
    required this.url,
    this.poster,
    this.autoplay = true,
    this.loop = false,
    this.fit = 'contain',
  });

  final String url;
  final String? poster;
  final bool autoplay;
  final bool loop;

  /// « contain » (toute la vidéo) ou « cover » (remplit, comme les reels).
  final String fit;

  static String html(String url, {String? poster, bool autoplay = true, bool loop = false, String fit = 'contain'}) {
    String a(String v) => const HtmlEscape(HtmlEscapeMode.attribute).convert(v);
    return '<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">'
        '<style>html,body{margin:0;height:100%;background:#000;overflow:hidden}'
        'video{width:100%;height:100%;object-fit:$fit;background:#000}</style></head><body>'
        '<video src="${a(url)}" ${poster == null ? '' : 'poster="${a(poster)}"'} controls playsinline '
        '${autoplay ? 'autoplay' : ''} ${loop ? 'loop' : ''}></video></body></html>';
  }

  @override
  Widget build(BuildContext context) {
    if (!webLoginSupported) {
      return Center(
        child: FilledButton.icon(
          icon: const Icon(Icons.play_arrow_rounded),
          label: const Text('Voir la vidéo'),
          onPressed: () => openLink(context, url),
        ),
      );
    }
    return InAppWebView(
      key: ValueKey(url),
      initialData: InAppWebViewInitialData(
        data: html(url, poster: poster, autoplay: autoplay, loop: loop, fit: fit),
        baseUrl: WebUri('https://www.instagram.com/'),
      ),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        mediaPlaybackRequiresUserGesture: false,
        allowsInlineMediaPlayback: true,
        transparentBackground: true,
      ),
    );
  }
}

/// Une miniature (photo, ou vidéo avec ▶) qui ouvre la visionneuse.
class MediaThumb extends StatelessWidget {
  const MediaThumb({
    super.key,
    required this.items,
    this.index = 0,
    this.width = 240,
    this.height = 240,
    this.radius = 14,
    this.fit = BoxFit.cover,
  });

  final List<MediaItem> items;
  final int index;
  final double width;
  final double height;
  final double radius;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final m = items[index];
    return GestureDetector(
      onTap: () => MediaViewer.open(context, items, index),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Container(
          width: width,
          height: height,
          color: const Color(0xFF1B1B1F),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (m.image != null)
                Image.network(
                  m.image!,
                  fit: fit,
                  // Décodée à la taille affichée (pas en 4K) : défilement fluide.
                  cacheWidth: (width * 2 * MediaQuery.devicePixelRatioOf(context)).round(),
                  errorBuilder: (_, _, _) => const Center(child: Icon(Icons.broken_image_rounded, color: Colors.white54)),
                ),
              if (m.isVideo)
                Center(
                  child: Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.45), shape: BoxShape.circle),
                    child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 36),
                  ),
                ),
              if (items.length > 1 && index == 0)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
                    child: Text('1/${items.length}', style: const TextStyle(color: Colors.white, fontSize: 11)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Photos et vidéos en plein écran : glisser ou ← → pour passer, molette ou
/// pincer pour zoomer, Échap pour fermer.
class MediaViewer extends StatefulWidget {
  const MediaViewer({super.key, required this.items, this.index = 0, this.caption});
  final List<MediaItem> items;
  final int index;
  final String? caption;

  static Future<void> open(BuildContext context, List<MediaItem> items, [int index = 0, String? caption]) =>
      Navigator.push(
        context,
        PageRouteBuilder<void>(
          opaque: true,
          pageBuilder: (_, _, _) => MediaViewer(items: items, index: index, caption: caption),
          transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
        ),
      );

  @override
  State<MediaViewer> createState() => _MediaViewerState();
}

class _MediaViewerState extends State<MediaViewer> {
  late final pages = PageController(initialPage: widget.index);
  late int i = widget.index;

  void _go(int to) {
    if (to < 0 || to >= widget.items.length) return;
    pages.animateToPage(to, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  @override
  void dispose() {
    pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.maybePop(context),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _go(i + 1),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _go(i - 1),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
              PageView.builder(
                controller: pages,
                itemCount: widget.items.length,
                onPageChanged: (p) => setState(() => i = p),
                itemBuilder: (context, p) {
                  final m = widget.items[p];
                  // Seule la vidéo affichée joue.
                  if (m.isVideo) {
                    return p == i ? WebVideo(url: m.video!, poster: m.image) : const SizedBox();
                  }
                  return InteractiveViewer(
                    maxScale: 5,
                    child: Center(
                      child: Image.network(
                        m.image ?? '',
                        fit: BoxFit.contain,
                        loadingBuilder: (c, child, prog) => prog == null
                            ? child
                            : const Center(child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white54)),
                        errorBuilder: (_, _, _) => const Icon(Icons.broken_image_rounded, color: Colors.white54, size: 60),
                      ),
                    ),
                  );
                },
              ),
              Positioned(
                top: 12,
                left: 12,
                child: IconButton.filled(
                  style: IconButton.styleFrom(backgroundColor: Colors.white24),
                  color: Colors.white,
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.maybePop(context),
                ),
              ),
              if (widget.items.length > 1) ...[
                Positioned(
                  top: 20,
                  right: 20,
                  child: Text('${i + 1} / ${widget.items.length}',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                ),
                if (i > 0)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: IconButton(
                      color: Colors.white,
                      iconSize: 40,
                      icon: const Icon(Icons.chevron_left_rounded),
                      onPressed: () => _go(i - 1),
                    ),
                  ),
                if (i < widget.items.length - 1)
                  Align(
                    alignment: Alignment.centerRight,
                    child: IconButton(
                      color: Colors.white,
                      iconSize: 40,
                      icon: const Icon(Icons.chevron_right_rounded),
                      onPressed: () => _go(i + 1),
                    ),
                  ),
              ],
              if (widget.caption != null && widget.caption!.trim().isNotEmpty)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(24, 30, 24, 24),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Colors.transparent, Colors.black87],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                    ),
                    child: Text(widget.caption!, maxLines: 4, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
