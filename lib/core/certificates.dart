import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:win32/win32.dart' show CERT_CONTEXT;

/// Les certificats de confiance des connexions sécurisées (https).
///
/// Sans ça, une connexion pouvait échouer avec « CERTIFICATE_VERIFY_FAILED :
/// unable to get local issuer certificate » (Spotify, École Directe…) :
/// * Windows ne télécharge certains certificats racines qu'au premier
///   besoin, et Mon Hub ne les avait pas encore ;
/// * un antivirus (analyse HTTPS) ou le réseau (école, contrôle parental)
///   signe les connexions avec son propre certificat, installé dans
///   Windows mais inconnu de Mon Hub.
///
/// Au démarrage, Mon Hub ajoute donc les certificats de Windows (racines et
/// intermédiaires) et la liste officielle de Mozilla (assets/cacert.pem).
class TrustedCertificates {
  TrustedCertificates._();

  static bool _done = false;

  static Future<void> install() async {
    if (_done || kIsWeb) return;
    _done = true;
    final ctx = SecurityContext.defaultContext;
    var added = 0;
    void add(String pem) {
      try {
        ctx.setTrustedCertificatesBytes(utf8.encode(pem));
        added++;
      } catch (_) {
        // Déjà connu, ou certificat illisible : on passe au suivant.
      }
    }

    try {
      final bundle = await rootBundle.loadString('assets/cacert.pem');
      for (final pem in splitPem(bundle)) {
        add(pem);
      }
    } catch (_) {}
    if (Platform.isWindows) {
      for (final store in const ['ROOT', 'CA']) {
        try {
          for (final der in _windowsStore(store)) {
            add(toPem(der));
          }
        } catch (_) {}
      }
    }
    debugPrint('Certificats ajoutés : $added');
  }

  /// Message clair pour une connexion sécurisée refusée (sinon null).
  static String? explain(Object e) {
    final t = '$e';
    if (e is! HandshakeException && !t.contains('CERTIFICATE_VERIFY_FAILED') && !t.contains('HandshakeException')) {
      return null;
    }
    return 'Connexion sécurisée refusée (certificat inconnu). Souvent, un antivirus (Avast, AVG, Kaspersky, '
        'Bitdefender, ESET…) ou le réseau de l\'école / un contrôle parental analyse les connexions : '
        'redémarre Mon Hub, et si ça continue, désactive « l\'analyse HTTPS » (ou « bouclier web ») de ton '
        'antivirus, ou essaie sur un autre réseau.';
  }

  /// Sépare un fichier PEM en certificats.
  @visibleForTesting
  static List<String> splitPem(String text) => [
    for (final m in RegExp(r'-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----').allMatches(text)) m[0]!,
  ];

  /// Un certificat (DER) au format PEM.
  @visibleForTesting
  static String toPem(List<int> der) {
    final b64 = base64.encode(der);
    final lines = [for (var i = 0; i < b64.length; i += 64) b64.substring(i, i + 64 > b64.length ? b64.length : i + 64)];
    return '-----BEGIN CERTIFICATE-----\n${lines.join('\n')}\n-----END CERTIFICATE-----\n';
  }

  /// Les certificats d'un magasin de Windows (« ROOT », « CA »).
  static List<Uint8List> _windowsStore(String name) {
    final crypt32 = DynamicLibrary.open('crypt32.dll');
    final open = crypt32.lookupFunction<Pointer Function(IntPtr, Pointer<Utf16>), Pointer Function(int, Pointer<Utf16>)>(
      'CertOpenSystemStoreW',
    );
    final next = crypt32.lookupFunction<
      Pointer<CERT_CONTEXT> Function(Pointer, Pointer<CERT_CONTEXT>),
      Pointer<CERT_CONTEXT> Function(Pointer, Pointer<CERT_CONTEXT>)
    >('CertEnumCertificatesInStore');
    final close = crypt32.lookupFunction<Int32 Function(Pointer, Uint32), int Function(Pointer, int)>('CertCloseStore');
    final out = <Uint8List>[];
    final n = name.toNativeUtf16();
    final store = open(0, n);
    calloc.free(n);
    if (store.address == 0) return out;
    try {
      var cert = next(store, nullptr);
      while (cert.address != 0 && out.length < 2000) {
        final c = cert.ref;
        if (c.cbCertEncoded > 0) out.add(Uint8List.fromList(c.pbCertEncoded.asTypedList(c.cbCertEncoded)));
        // CertEnumCertificatesInStore libère le précédent tout seul.
        cert = next(store, cert);
      }
    } finally {
      close(store, 0);
    }
    return out;
  }
}
