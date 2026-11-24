/// Hors navigateur (tests) : rien ne se passe.
class PhoneBridge {
  PhoneBridge._();

  static bool get standalone => false;
  static bool get ios => false;
  static String get notifyState => 'absent';
  static Future<String> askNotify() async => 'absent';
  static Future<bool> notify(String title, String body, {String tag = ''}) async => false;
  static Future<bool> share(String text) async => false;
  static bool vibrate(int ms) => false;
  static void openFile(String name, String mime, String text) {}
  static String get hash => '';
  static void clearHash() {}
  static bool get hidden => false;
}
