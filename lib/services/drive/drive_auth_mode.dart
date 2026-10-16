// drive_auth_mode.dart — which sign-in a Drive server uses.
//
// GET <base>/api/v1/auth/config → {"data":{"mode":"sso"|"ad"}}
//   sso — the WorldPosta SSO login (DriveConstants.ssoAuthUrl)
//   ad  — the Drive's own login page (<base>/login), checked against the
//         organization's Active Directory. Used until the SSO is available.
// Servers without the endpoint (older builds, HTTP 404) are SSO. Any other
// failure is `unavailable`: never guess SSO, which would send users of an AD
// deployment to an SSO login that doesn't exist.

import 'dart:convert';
import 'dart:io';

enum DriveAuthMode { sso, ad, unavailable }

class DriveAuthModeProbe {
  static Future<DriveAuthMode> fetch(String serverBase) async {
    final base = serverBase.endsWith('/')
        ? serverBase.substring(0, serverBase.length - 1)
        : serverBase;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.getUrl(Uri.parse('$base/api/v1/auth/config'));
      final res = await req.close().timeout(const Duration(seconds: 8));
      if (res.statusCode == HttpStatus.notFound) return DriveAuthMode.sso;
      if (res.statusCode != HttpStatus.ok) return DriveAuthMode.unavailable;
      final body = await res.transform(utf8.decoder).join();
      final j = jsonDecode(body);
      final mode = (j is Map && j['data'] is Map) ? j['data']['mode'] : null;
      return mode == 'ad' ? DriveAuthMode.ad : DriveAuthMode.sso;
    } catch (_) {
      return DriveAuthMode.unavailable;
    } finally {
      client.close(force: true);
    }
  }
}
