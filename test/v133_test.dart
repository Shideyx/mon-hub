import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/certificates.dart';

void main() {
  test('certificats : liste de Mozilla lisible et convertie', () {
    final bundle = File('assets/cacert.pem').readAsStringSync();
    final certs = TrustedCertificates.splitPem(bundle);
    expect(certs.length, greaterThan(100));
    // Un certificat de Windows (DER) remis au format PEM est accepté.
    final body = certs.first
        .replaceAll('-----BEGIN CERTIFICATE-----', '')
        .replaceAll('-----END CERTIFICATE-----', '')
        .replaceAll(RegExp(r'\s'), '');
    final pem = TrustedCertificates.toPem(base64.decode(body));
    expect(pem, startsWith('-----BEGIN CERTIFICATE-----\n'));
    final ctx = SecurityContext(withTrustedRoots: false);
    ctx.setTrustedCertificatesBytes(utf8.encode(pem));
  });

  test('certificats : message clair pour Spotify', () {
    final m = TrustedCertificates.explain(
      const HandshakeException(
        'Handshake error in client (OS Error: CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate)',
      ),
    );
    expect(m, contains('antivirus'));
    expect(TrustedCertificates.explain('autre erreur'), isNull);
  });
}
