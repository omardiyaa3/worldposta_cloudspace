import 'dart:convert';

import 'package:cloudspace_app/services/drive/drive_sso_password_login.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// The SSO's ResultObject envelope, as adminserver.worldposta.com answers.
String _envelope({bool ok = false, Map<String, dynamic>? result, String? message}) => jsonEncode({
      'Succeeded': ok,
      'Failed': !ok,
      'Result': result,
      'Messages': [if (message != null) {'MessageType': 1, 'Message': message}],
    });

DriveSsoPasswordLogin _sso(Future<http.Response> Function(http.Request) handler) =>
    DriveSsoPasswordLogin(client: MockClient(handler), ssoApiUrl: 'https://sso.test/');

void main() {
  test('password sign-in returns the access token', () async {
    late http.Request sent;
    final step = await _sso((r) async {
      sent = r;
      return http.Response(_envelope(ok: true, result: {'AccessToken': 'a.b.c', 'ExpiresIn': 900}), 200);
    }).login(' user@org.com ', 'pw');
    expect(sent.url.toString(), 'https://sso.test/api/auth/login');
    expect(jsonDecode(sent.body), {'email': 'user@org.com', 'password': 'pw'});
    expect(step, isA<SsoSignedIn>().having((s) => s.accessToken, 'accessToken', 'a.b.c'));
  });

  test('an emailed-code challenge asks for the code, then verify signs in', () async {
    final first = await _sso((r) async => http.Response(
        _envelope(result: {'Action': 'OtpRequired', 'Email': 'user@org.com'},
            message: 'A verification code was sent to your email.'),
        200)).login('user@org.com', 'pw');
    expect(first, isA<SsoCodeRequired>().having((s) => s.email, 'email', 'user@org.com'));

    late http.Request sent;
    final second = await _sso((r) async {
      sent = r;
      return http.Response(_envelope(ok: true, result: {'AccessToken': 'x.y.z'}), 200);
    }).verifyCode('user@org.com', 'pw', ' 123456 ');
    expect(sent.url.path, '/api/auth/mfa/verify');
    expect(jsonDecode(sent.body), {'email': 'user@org.com', 'password': 'pw', 'code': '123456'});
    expect(second, isA<SsoSignedIn>());
  });

  test('SSO refusals become friendly messages', () async {
    for (final c in {
      'Invalid username or password': 'Wrong email or password.',
      'account locked': 'Too many failed attempts',
      'account unavailable': 'disabled',
      'Invalid or expired code': 'wrong or has expired',
    }.entries) {
      await expectLater(
        _sso((r) async => http.Response(_envelope(message: c.key), 200)).login('a@b.c', 'x'),
        throwsA(isA<SsoSignInException>().having((e) => e.message, 'message', contains(c.value))),
      );
    }
    await expectLater(
      _sso((r) async => http.Response('', 429)).login('a@b.c', 'x'),
      throwsA(isA<SsoSignInException>().having((e) => e.message, 'message', contains('Too many'))),
    );
  });

  test('the SSO token is exchanged for a dk_ Drive token', () async {
    late http.Request sent;
    final token = await _sso((r) async {
      sent = r;
      return http.Response(jsonEncode({'data': {'token': 'dk_abc', 'id': '1'}}), 201);
    }).mintDriveToken('https://drive.test/', 'a.b.c');
    expect(sent.url.toString(), 'https://drive.test/api/v1/me/tokens');
    expect(sent.headers['Authorization'], 'Bearer a.b.c');
    expect(token, 'dk_abc');

    await expectLater(
      _sso((r) async => http.Response(jsonEncode({'error': {'code': 'unauthenticated', 'message': 'jwt'}}), 401))
          .mintDriveToken('https://drive.test', 'bad'),
      throwsA(isA<SsoSignInException>()),
    );
  });
}
