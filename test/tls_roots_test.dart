import 'dart:convert';
import 'dart:io';

import 'package:cloudspace_app/services/drive/tls_roots.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the bundled R46 root parses', () {
    expect(() => SecurityContext(withTrustedRoots: false)
        .setTrustedCertificatesBytes(utf8.encode(sectigoRootR46)), returnsNormally);
    expect(appSecurityContext(), same(appSecurityContext()));
  });

  // Live check, opt-in: CHECK_LIVE_TLS=1 flutter test test/tls_roots_test.dart
  test('drive.worldposta.com verifies against the bundled root ALONE', () async {
    final ctx = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificatesBytes(utf8.encode(sectigoRootR46));
    final s = await SecureSocket.connect('drive.worldposta.com', 443, context: ctx, timeout: const Duration(seconds: 10));
    expect(s.peerCertificate?.subject, contains('worldposta.com'));
    await s.close();
    await expectLater(
      SecureSocket.connect('drive.worldposta.com', 443,
          context: SecurityContext(withTrustedRoots: false), timeout: const Duration(seconds: 10)),
      throwsA(isA<HandshakeException>()),
    );
  }, skip: Platform.environment['CHECK_LIVE_TLS'] != '1');
}
