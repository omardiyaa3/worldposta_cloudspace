import 'dart:convert';
import 'dart:io';

import 'package:cloudspace_app/services/drive/drive_auth_mode.dart';
import 'package:flutter_test/flutter_test.dart';

Future<HttpServer> _serve(int status, String body) async {
  final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  s.listen((req) {
    req.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(body);
    req.response.close();
  });
  return s;
}

void main() {
  test('ad mode is detected', () async {
    final s = await _serve(200, jsonEncode({'data': {'mode': 'ad'}}));
    expect(await DriveAuthModeProbe.fetch('http://127.0.0.1:${s.port}/'), DriveAuthMode.ad);
    await s.close(force: true);
  });

  test('sso mode and older servers (404) mean sso', () async {
    for (final c in [
      [200, jsonEncode({'data': {'mode': 'sso'}})],
      [404, '{"error":{"code":"not_found"}}'],
    ]) {
      final s = await _serve(c[0] as int, c[1] as String);
      expect(await DriveAuthModeProbe.fetch('http://127.0.0.1:${s.port}'), DriveAuthMode.sso);
      await s.close(force: true);
    }
  });

  test('errors never guess sso: unavailable', () async {
    for (final c in [
      [500, '{}'],
      [200, 'not json'],
    ]) {
      final s = await _serve(c[0] as int, c[1] as String);
      expect(await DriveAuthModeProbe.fetch('http://127.0.0.1:${s.port}'), DriveAuthMode.unavailable);
      await s.close(force: true);
    }
    expect(await DriveAuthModeProbe.fetch('http://127.0.0.1:1'), DriveAuthMode.unavailable);
  });

}
