import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'cam_blur.dart';

/// Allume la détection des visages dans le navigateur intégré (WebView2)
/// **avant** qu'il s'ouvre, pour tous les programmes de Mon Hub (le
/// navigateur refuse de s'ouvrir si deux programmes demandent des
/// arguments différents).
void enableFaceDetection() {
  if (!Platform.isWindows) return;
  const name = 'WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS';
  final value = CamBlur.withArgs(Platform.environment[name]);
  try {
    using((a) => SetEnvironmentVariable(name.toPcwstr(allocator: a), value.toPcwstr(allocator: a)));
  } catch (_) {}
}
