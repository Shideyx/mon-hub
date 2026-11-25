import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_ui/material_ui.dart';

import '../core/ai_text.dart';
import '../core/safe_open.dart';
import '../modules/docs/doc_format.dart';
import 'web_login.dart';
import 'widgets.dart';

/// Ce qu'on sait afficher d'un fichier.
enum FileKind { pdf, image, text, word, media, other }

/// Voir une pièce jointe **dans Mon Hub** (devoirs École Directe, messages,
/// mails, cloud) : PDF (lecteur PDF d'Edge), photos, texte, Word (texte),
/// sons et vidéos. Le reste s'ouvre avec l'appli du PC. Le fichier est gardé
/// dans un dossier temporaire, effacé au bout d'un jour.
class FileViewer extends StatefulWidget {
  const FileViewer({super.key, required this.name, required this.load});

  /// Nom du fichier (avec son extension : « exercices.pdf »).
  final String name;

  /// Télécharge le fichier (appelé une seule fois).
  final Future<List<int>> Function() load;

  static Future<void> open(BuildContext context, String name, Future<List<int>> Function() load) => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => FileViewer(name: name, load: load),
    ),
  );

  static String extOf(String name) {
    final n = name.trim().toLowerCase();
    final dot = n.lastIndexOf('.');
    return dot < 0 || dot == n.length - 1 ? '' : n.substring(dot + 1);
  }

  static const _images = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'};
  static const _texts = {
    'txt',
    'csv',
    'md',
    'json',
    'xml',
    'log',
    'ini',
    'tex',
    'py',
    'dart',
    'js',
    'css',
    'java',
    'c',
    'cpp',
  };
  static const _media = {'mp3', 'wav', 'm4a', 'ogg', 'oga', 'opus', 'aac', 'flac', 'mp4', 'webm', 'mov', 'm4v'};

  /// Type d'un fichier d'après son nom (et ses premiers octets s'il n'a pas
  /// d'extension connue).
  static FileKind kindOf(String name, [List<int>? head]) {
    final ext = extOf(name);
    if (ext == 'pdf') return FileKind.pdf;
    if (_images.contains(ext)) return FileKind.image;
    if (_texts.contains(ext)) return FileKind.text;
    if (ext == 'docx') return FileKind.word;
    if (_media.contains(ext)) return FileKind.media;
    final h = head;
    if (h != null && h.length >= 4) {
      if (h[0] == 0x25 && h[1] == 0x50 && h[2] == 0x44 && h[3] == 0x46) return FileKind.pdf; // %PDF
      if (h[0] == 0x89 && h[1] == 0x50 && h[2] == 0x4E && h[3] == 0x47) return FileKind.image; // PNG
      if (h[0] == 0xFF && h[1] == 0xD8) return FileKind.image; // JPEG
      if (h[0] == 0x47 && h[1] == 0x49 && h[2] == 0x46) return FileKind.image; // GIF
    }
    return FileKind.other;
  }

  /// Extension à ajouter à un fichier sans extension (pour que Windows sache
  /// l'ouvrir).
  static String guessExt(List<int> head) => switch (kindOf('', head)) {
    FileKind.pdf => 'pdf',
    FileKind.image => head.isNotEmpty && head[0] == 0xFF ? 'jpg' : (head.isNotEmpty && head[0] == 0x47 ? 'gif' : 'png'),
    _ => '',
  };

  static IconData iconFor(String name) => switch (extOf(name)) {
    'pdf' => Icons.picture_as_pdf_rounded,
    'doc' || 'docx' || 'odt' || 'txt' || 'rtf' => Icons.description_rounded,
    'xls' || 'xlsx' || 'ods' || 'csv' => Icons.table_chart_rounded,
    'ppt' || 'pptx' || 'odp' => Icons.slideshow_rounded,
    'png' || 'jpg' || 'jpeg' || 'gif' || 'webp' || 'bmp' => Icons.image_rounded,
    'mp3' || 'wav' || 'm4a' || 'ogg' || 'opus' || 'aac' || 'flac' => Icons.audio_file_rounded,
    'mp4' || 'mov' || 'avi' || 'mkv' || 'webm' => Icons.video_file_rounded,
    'zip' || 'rar' || '7z' => Icons.folder_zip_rounded,
    _ => Icons.insert_drive_file_rounded,
  };

  static String safeName(String name) {
    final s = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_').trim();
    final t = s.isEmpty ? 'fichier' : s;
    return t.length > 120 ? t.substring(t.length - 120) : t;
  }

  /// L'IA lit un document (PDF, photo, Word, texte) et en donne l'essentiel
  /// pour un lycéen : ce qu'il faut faire, puis le contenu en quelques points.
  ///
  /// [full] : recopie **tout** le texte (l'énoncé complet d'un devoir, pour
  /// le faire), au lieu de le résumer.
  static Future<String> summarize(String name, Uint8List bytes, {String? text, bool full = false}) async {
    final ask = full
        ? 'Recopie intégralement tout le texte de ce document, dans l\'ordre : consignes, énoncés, questions, données, '
              'tableaux (en texte), formules. Ne résume pas, ne réponds pas aux questions, n\'ajoute rien.'
        : 'Voici un document (pièce jointe d\'un devoir, d\'un message ou d\'un mail). Résume-le pour un lycéen, '
              'en français : d\'abord ce qu\'il faut faire (consignes, à rendre, dates), puis l\'essentiel du contenu en '
              'quelques points courts. Pas d\'introduction.';
    final kind = kindOf(name, bytes.take(16).toList());
    if (kind == FileKind.pdf) {
      if (!await AiText.hasGemini()) {
        throw 'Pour lire un PDF, Nexo a besoin de ta clé Gemini gratuite (Réglages de Nexo → Voix).';
      }
      if (bytes.length > 15 * 1024 * 1024) throw 'Ce PDF est trop gros pour être lu par l\'IA (15 Mo au plus).';
      return AiText.ask(ask, pdf: base64Encode(bytes));
    }
    if (kind == FileKind.image) return AiText.ask(ask, images: [base64Encode(bytes)]);
    var t = text;
    if (t == null && kind == FileKind.word) {
      t = await Isolate.run(() => DocFormat.toMarkdown(DocFormat.fromDocx(bytes)));
    } else if (t == null && kind == FileKind.text) {
      t = await Isolate.run(() => _FileViewerState._decodeText(bytes));
    }
    if (t == null || t.trim().isEmpty) throw 'Je ne sais pas lire ce type de fichier';
    // Un Word ou un texte : son texte tel quel suffit pour l'énoncé.
    if (full) return t.length > 60000 ? '${t.substring(0, 60000)}…' : t;
    return AiText.ask('$ask\n\n---\n${t.length > 60000 ? t.substring(0, 60000) : t}');
  }

  static bool _cleaned = false;

  /// Le dossier des aperçus (les vieux aperçus sont effacés une fois par
  /// lancement).
  static Future<Directory> _previewDir() async {
    final root = Directory('${Directory.systemTemp.path}${Platform.pathSeparator}MonHub-apercus');
    await root.create(recursive: true);
    if (!_cleaned) {
      _cleaned = true;
      unawaited(() async {
        try {
          await for (final e in root.list()) {
            final age = DateTime.now().difference((await e.stat()).modified);
            if (age > const Duration(days: 1)) await e.delete(recursive: true);
          }
        } catch (_) {}
      }());
    }
    final d = Directory('${root.path}${Platform.pathSeparator}${DateTime.now().microsecondsSinceEpoch}');
    await d.create();
    return d;
  }

  @override
  State<FileViewer> createState() => _FileViewerState();
}

/// Le fichier téléchargé et prêt à afficher.
class _Loaded {
  _Loaded(this.bytes, this.path, this.kind, {this.text});
  final Uint8List bytes;
  final String path;
  final FileKind kind;

  /// Texte affiché (fichier texte, ou texte d'un Word).
  final String? text;
}

class _FileViewerState extends State<FileViewer> {
  late final Future<_Loaded> _file = _prepare();
  bool _summarizing = false;

  String get _name => FileViewer.safeName(widget.name);

  Future<_Loaded> _prepare() async {
    final raw = await widget.load();
    final bytes = raw is Uint8List ? raw : Uint8List.fromList(raw);
    if (bytes.isEmpty) throw 'Le fichier est vide';
    final head = bytes.take(16).toList();
    var name = _name;
    if (FileViewer.extOf(name).isEmpty) {
      final ext = FileViewer.guessExt(head);
      if (ext.isNotEmpty) name = '$name.$ext';
    }
    final kind = FileViewer.kindOf(name, head);
    final dir = await FileViewer._previewDir();
    final f = File('${dir.path}${Platform.pathSeparator}$name');
    await f.writeAsBytes(bytes, flush: true);
    String? text;
    if (kind == FileKind.text) {
      text = await Isolate.run(() => _decodeText(bytes));
    } else if (kind == FileKind.word) {
      try {
        // Hors du fil de l'interface : un gros .docx ne fige pas l'appli.
        text = await Isolate.run(() => DocFormat.toMarkdown(DocFormat.fromDocx(bytes)));
      } catch (_) {
        text = null;
      }
    }
    return _Loaded(bytes, f.path, kind, text: text);
  }

  static String _decodeText(Uint8List bytes) {
    final cut = bytes.length > 600000 ? bytes.sublist(0, 600000) : bytes;
    try {
      return utf8.decode(cut);
    } on FormatException {
      return latin1.decode(cut, allowInvalid: true);
    }
  }

  Future<void> _openOutside(_Loaded f) async {
    if (SafeOpen.risky(f.path)) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          icon: const Icon(Icons.warning_amber_rounded),
          title: const Text('Ce fichier peut lancer un programme'),
          content: Text(
            '« ${widget.name} » n\'est pas un simple document. Ne l\'ouvre que si tu as confiance en l\'expéditeur.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Annuler')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Ouvrir quand même')),
          ],
        ),
      );
      if (ok != true) return;
    }
    final ok = await SafeOpen.launch(f.path);
    if (!ok && mounted) showError(context, 'Aucune appli de ce PC ne sait ouvrir ce fichier');
  }

  Future<void> _saveAs(_Loaded f) async {
    try {
      final loc = await getSaveLocation(suggestedName: f.path.split(Platform.pathSeparator).last);
      if (loc == null) return;
      await File(loc.path).writeAsBytes(f.bytes, flush: true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Enregistré : ${loc.path}')));
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  bool _canSummarize(_Loaded f) =>
      f.kind == FileKind.pdf || f.kind == FileKind.image || (f.text?.trim().isNotEmpty ?? false);

  /// L'IA lit le document et en fait l'essentiel (consignes, dates…).
  Future<void> _summarize(_Loaded f) async {
    setState(() => _summarizing = true);
    try {
      final out = await FileViewer.summarize(f.path, f.bytes, text: f.text);
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (c) => ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * 0.8),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            children: [
              Row(
                children: [
                  const Icon(Icons.auto_awesome_rounded, color: Color(0xFF7C5CFF)),
                  const SizedBox(width: 8),
                  Expanded(child: Text('L\'essentiel', style: Theme.of(c).textTheme.titleLarge)),
                  IconButton(
                    tooltip: 'Copier',
                    icon: const Icon(Icons.copy_rounded),
                    onPressed: () => Clipboard.setData(ClipboardData(text: out)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SelectableText(out, style: const TextStyle(height: 1.5)),
            ],
          ),
        ),
      );
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _summarizing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_Loaded>(
      future: _file,
      builder: (context, snap) {
        final f = snap.data;
        return Scaffold(
          appBar: AppBar(
            title: Row(
              children: [
                Icon(FileViewer.iconFor(widget.name), size: 22),
                const SizedBox(width: 10),
                Expanded(child: Text(widget.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
              ],
            ),
            actions: f == null
                ? null
                : [
                    if (_canSummarize(f))
                      _summarizing
                          ? const Padding(
                              padding: EdgeInsets.all(14),
                              child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                            )
                          : TextButton.icon(
                              icon: const Icon(Icons.auto_awesome_rounded),
                              label: const Text('Résumer'),
                              onPressed: () => _summarize(f),
                            ),
                    IconButton(
                      tooltip: 'Enregistrer sous…',
                      icon: const Icon(Icons.download_rounded),
                      onPressed: () => _saveAs(f),
                    ),
                    IconButton(
                      tooltip: 'Ouvrir avec l\'appli du PC',
                      icon: const Icon(Icons.open_in_new_rounded),
                      onPressed: () => _openOutside(f),
                    ),
                    const SizedBox(width: 6),
                  ],
          ),
          body: snap.hasError
              ? EmptyHint('Impossible d\'ouvrir ce fichier : ${snap.error}', icon: Icons.error_outline_rounded)
              : f == null
              ? const Center(child: LoadingHint())
              : _body(context, f),
        );
      },
    );
  }

  Widget _body(BuildContext context, _Loaded f) {
    switch (f.kind) {
      case FileKind.image:
        return ColoredBox(
          color: Colors.black,
          child: InteractiveViewer(
            maxScale: 6,
            child: Center(
              child: Image.memory(
                f.bytes,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const Icon(Icons.broken_image_rounded, color: Colors.white54, size: 60),
              ),
            ),
          ),
        );
      case FileKind.text:
      case FileKind.word:
        final t = f.text;
        if (t == null || t.trim().isEmpty) return _other(context, f, 'Pas d\'aperçu pour ce document.');
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(28, 20, 28, 40),
              children: [
                if (f.kind == FileKind.word)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      'Aperçu du texte (mise en page simplifiée). Pour la vraie mise en page : « Ouvrir avec l\'appli du PC ».',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                SelectableText(
                  t,
                  style: TextStyle(height: 1.5, fontFamily: f.kind == FileKind.text ? 'Consolas' : null),
                ),
              ],
            ),
          ),
        );
      case FileKind.pdf:
      case FileKind.media:
        if (!webLoginSupported) return _other(context, f, 'L\'aperçu n\'est pas disponible sur cet appareil.');
        // Le lecteur PDF et le lecteur audio/vidéo d'Edge (WebView2).
        return InAppWebView(
          initialUrlRequest: URLRequest(url: WebUri(Uri.file(f.path).toString())),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            mediaPlaybackRequiresUserGesture: false,
            allowsInlineMediaPlayback: true,
            supportMultipleWindows: false,
          ),
        );
      case FileKind.other:
        return _other(context, f, 'Mon Hub ne sait pas encore afficher ce type de fichier.');
    }
  }

  Widget _other(BuildContext context, _Loaded f, String why) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(FileViewer.iconFor(widget.name), size: 72, color: theme.colorScheme.primary),
            const SizedBox(height: 12),
            Text(widget.name, textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(why, textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
            const SizedBox(height: 18),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              alignment: WrapAlignment.center,
              children: [
                FilledButton.icon(
                  icon: const Icon(Icons.open_in_new_rounded),
                  label: const Text('Ouvrir avec l\'appli du PC'),
                  onPressed: () => _openOutside(f),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.download_rounded),
                  label: const Text('Enregistrer sous…'),
                  onPressed: () => _saveAs(f),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Une pièce jointe sous forme de pastille (devoirs, messages, mails).
class AttachmentChip extends StatelessWidget {
  const AttachmentChip({super.key, required this.name, required this.load});
  final String name;
  final Future<List<int>> Function() load;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ActionChip(
      avatar: Icon(FileViewer.iconFor(name), size: 18, color: scheme.primary),
      label: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 260),
        child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      tooltip: 'Voir le fichier',
      onPressed: () => FileViewer.open(context, name, load),
    );
  }
}
