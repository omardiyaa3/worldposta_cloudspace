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

import 'package:http/http.dart' as http;

import 'http_client.dart';

enum DriveAuthMode { sso, ad, unavailable }

class DriveAuthModeProbe {
  /// Asks the server how it signs users in. Retries a few times (App Review
  /// and mobile networks can be slow to connect) before saying unavailable.
  static Future<DriveAuthMode> fetch(String serverBase, {http.Client? client, int attempts = 3}) async {
    final base = serverBase.endsWith('/')
        ? serverBase.substring(0, serverBase.length - 1)
        : serverBase;
    final c = client ?? newDriveHttpClient();
    try {
      for (var i = 0; i < attempts; i++) {
        if (i > 0) await Future<void>.delayed(Duration(seconds: 2 * i));
        try {
          final res = await c.get(Uri.parse('$base/api/v1/auth/config')).timeout(const Duration(seconds: 12));
          if (res.statusCode == 404) return DriveAuthMode.sso;
          if (res.statusCode != 200) continue;
          final j = jsonDecode(utf8.decode(res.bodyBytes));
          final mode = (j is Map && j['data'] is Map) ? j['data']['mode'] : null;
          return mode == 'ad' ? DriveAuthMode.ad : DriveAuthMode.sso;
        } catch (_) {
          // network error / timeout / bad body: try again
        }
      }
      return DriveAuthMode.unavailable;
    } finally {
      if (client == null) c.close();
    }
  }
}
