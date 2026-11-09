// drive_sso_password_login.dart — native sign-in against the WorldPosta SSO's
// mobile endpoints, so the app never shows the SSO's web sign-in page.
//
//   POST <ssoApi>/api/auth/login       {email, password}       → tokens, or an
//        emailed-code challenge (Result.Action == "OtpRequired") when the
//        account has two-factor sign-in or Smart OTP fires
//   POST <ssoApi>/api/auth/mfa/verify  {email, password, code} → tokens
//
// Both answer HTTP 200 with the SSO's ResultObject envelope:
//   {"Succeeded":bool, "Result":{AccessToken, Action, Email, …}|null,
//    "Messages":[{"MessageType":1,"Message":"…"}]}
// The access token is the SSO's RS256 product token, which the Drive verifies
// itself (JWKS). With it we mint a `dk_` Drive token (POST /api/v1/me/tokens,
// allowed for an identity-provider token) and from there the account is stored
// exactly like a pasted token. The SSO tokens are not kept.

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../config/drive_constants.dart';
import 'http_client.dart';

/// What the SSO said about an email + password (or code).
sealed class SsoSignInStep {}

/// Signed in: the SSO's access token, good for a few minutes.
class SsoSignedIn extends SsoSignInStep {
  final String accessToken;
  SsoSignedIn(this.accessToken);
}

/// A code was emailed to [email]; call [DriveSsoPasswordLogin.verifyCode].
class SsoCodeRequired extends SsoSignInStep {
  final String email;
  SsoCodeRequired(this.email);
}

class SsoSignInException implements Exception {
  final String message;
  SsoSignInException(this.message);
  @override
  String toString() => message;
}

class DriveSsoPasswordLogin {
  final http.Client _http;
  final String _sso;

  DriveSsoPasswordLogin({http.Client? client, String ssoApiUrl = DriveConstants.ssoApiUrl})
      : _http = client ?? newDriveHttpClient(),
        _sso = ssoApiUrl.endsWith('/') ? ssoApiUrl.substring(0, ssoApiUrl.length - 1) : ssoApiUrl;

  void close() => _http.close();

  Future<SsoSignInStep> login(String email, String password) =>
      _call('/api/auth/login', {'email': email.trim(), 'password': password});

  Future<SsoSignInStep> verifyCode(String email, String password, String code) =>
      _call('/api/auth/mfa/verify', {'email': email.trim(), 'password': password, 'code': code.trim()});

  Future<SsoSignInStep> _call(String path, Map<String, String> body) async {
    final http.Response res;
    try {
      res = await _http
          .post(Uri.parse('$_sso$path'),
              headers: const {'Content-Type': 'application/json', 'Accept': 'application/json'},
              body: jsonEncode(body))
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw SsoSignInException("Can't reach the WorldPosta sign-in service. Check your connection and try again.");
    }
    if (res.statusCode == 429) {
      throw SsoSignInException('Too many sign-in attempts. Wait a minute, then try again.');
    }
    Map<String, dynamic>? j;
    try {
      final d = jsonDecode(utf8.decode(res.bodyBytes));
      if (d is Map<String, dynamic>) j = d;
    } catch (_) {}
    if (res.statusCode != 200 || j == null) {
      throw SsoSignInException('The sign-in service had a problem (${res.statusCode}). Please try again.');
    }
    final r = j['Result'] is Map ? j['Result'] as Map : const {};
    if (r['Action'] == 'OtpRequired') {
      return SsoCodeRequired((r['Email'] as String?) ?? body['email']!);
    }
    final token = r['AccessToken'];
    if (j['Succeeded'] == true && token is String && token.isNotEmpty) return SsoSignedIn(token);
    throw SsoSignInException(_friendly(_firstMessage(j)));
  }

  static String _firstMessage(Map<String, dynamic> j) {
    final m = j['Messages'];
    if (m is List && m.isNotEmpty && m.first is Map) return '${(m.first as Map)['Message'] ?? ''}';
    return '';
  }

  static String _friendly(String m) {
    final s = m.toLowerCase();
    if (s.contains('invalid username or password')) return 'Wrong email or password.';
    if (s.contains('locked')) return 'Too many failed attempts: this account is locked for now. Try again later.';
    if (s.contains('account unavailable')) return 'This account is disabled. Contact your administrator.';
    if (s.contains('invalid or expired code')) return 'That code is wrong or has expired.';
    if (s.contains('required')) return 'Enter your email and password.';
    return m.isEmpty ? 'Sign-in failed. Please try again.' : m;
  }

  /// Exchanges the SSO access token for a long-lived `dk_` token on the Drive.
  Future<String> mintDriveToken(String serverBase, String accessToken) async {
    final base = serverBase.endsWith('/') ? serverBase.substring(0, serverBase.length - 1) : serverBase;
    final http.Response res;
    try {
      res = await _http
          .post(Uri.parse('$base/api/v1/me/tokens'),
              headers: {
                'Authorization': 'Bearer $accessToken',
                'Content-Type': 'application/json',
                'Accept': 'application/json',
              },
              body: jsonEncode({'name': 'Posta Drive app', 'scopes': ['clouddrive:write']}))
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw SsoSignInException("Can't reach the Drive server. Check your connection and try again.");
    }
    Map? j;
    try {
      final d = jsonDecode(utf8.decode(res.bodyBytes));
      if (d is Map) j = d;
    } catch (_) {}
    final data = j?['data'];
    final token = data is Map ? data['token'] : null;
    if (res.statusCode < 300 && token is String && token.startsWith('dk_')) return token;
    final err = j?['error'];
    final msg = err is Map ? '${err['message'] ?? ''}' : '';
    if (res.statusCode == 401) {
      throw SsoSignInException("Posta Drive didn't accept this sign-in. Please try again.");
    }
    throw SsoSignInException(msg.isNotEmpty ? msg : 'Posta Drive had a problem signing you in (${res.statusCode}).');
  }
}
