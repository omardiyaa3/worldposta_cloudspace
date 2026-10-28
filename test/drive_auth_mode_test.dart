import 'dart:convert';
import 'dart:io';

import 'package:cloudspace_app/services/drive/drive_auth_mode.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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
      expect(await DriveAuthModeProbe.fetch('http://127.0.0.1:${s.port}', attempts: 1), DriveAuthMode.unavailable);
      await s.close(force: true);
    }
    expect(await DriveAuthModeProbe.fetch('http://127.0.0.1:1', attempts: 1), DriveAuthMode.unavailable);
  });

  test('a slow or failed first connection is retried before giving up', () async {
    var calls = 0;
    final flaky = MockClient((req) async {
      calls++;
      if (calls < 3) throw http.ClientException('connection failed');
      return http.Response(jsonEncode({'data': {'mode': 'ad'}}), 200);
    });
    expect(await DriveAuthModeProbe.fetch('https://drive.example', client: flaky), DriveAuthMode.ad);
    expect(calls, 3);

    calls = 0;
    final down = MockClient((req) async { calls++; throw http.ClientException('down'); });
    expect(await DriveAuthModeProbe.fetch('https://drive.example', client: down), DriveAuthMode.unavailable);
    expect(calls, 3);
  });
}
