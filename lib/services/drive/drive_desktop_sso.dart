// drive_desktop_sso.dart — one-click SSO for the desktop app via a browser +
// loopback redirect (the standard "OAuth for native apps" pattern; RFC 8252).
//
// Embedded desktop webviews are unreliable (WebView2 on Windows, WKWebView on
// macOS), so we never embed the login. Instead:
//   1. bind a throwaway HTTP server on 127.0.0.1:<random free port>;
//   2. open the user's real browser at
//        <base>/api/v1/auth/desktop?callback=http://127.0.0.1:<port>/callback&state=<nonce>
//   3. the backend authenticates the browser via the existing WorldPosta SSO
//      session (redirecting to the SSO login first if needed), mints a `dk_`
//      Drive token for that user, then 302-redirects to our loopback callback
//      with ?token=<dk_…>&state=<nonce>;
//   4. we capture the token, verify the state nonce (CSRF guard), show a
//      "you can close this tab" page, and hand the token back — from there it is
//      validated and stored exactly like a pasted token.
//
// The loopback server binds to 127.0.0.1 only (never a routable interface), and
// the random `state` nonce prevents another local process from injecting a token.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:url_launcher/url_launcher.dart';

import '../../config/drive_constants.dart';

class DesktopSsoException implements Exception {
  final String message;
  DesktopSsoException(this.message);
  @override
  String toString() => message;
}

class DriveDesktopSso {
  static const Duration _timeout = Duration(minutes: 5);

  static String _nonce() {
    final r = Random.secure();
    return List.generate(24, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  /// Runs the loopback handshake and returns the minted `dk_` token.
  /// [serverBase] e.g. https://portal.worldposta.com:2023.
  static Future<String> signIn(String serverBase) async {
    final base = serverBase.endsWith('/') ? serverBase.substring(0, serverBase.length - 1) : serverBase;
    final state = _nonce();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    try {
      final callback = 'http://127.0.0.1:${server.port}/callback';
      // Route THROUGH the SSO login with return_to pointing at the Drive's desktop
      // endpoint. The app builds that endpoint URL itself, so it keeps the correct
      // host:port (a reverse proxy strips :2023 from the backend's own Host header,
      // so we must NOT let the backend reconstruct the return URL). After signing
      // in, the browser lands on /auth/desktop already carrying the wp_session
      // cookie → the backend mints a dk_ token and 302s to our loopback callback.
      final endpoint = '$base/api/v1/auth/desktop'
          '?callback=${Uri.encodeQueryComponent(callback)}'
          '&state=$state';
      final authUrl = Uri.parse(
        '${DriveConstants.ssoAuthUrl}/login?return_to=${Uri.encodeQueryComponent(endpoint)}',
      );

      final launched = await launchUrl(authUrl, mode: LaunchMode.externalApplication);
      if (!launched) {
        throw DesktopSsoException('Could not open your browser to sign in.');
      }

      final completer = Completer<String>();
      final timer = Timer(_timeout, () {
        if (!completer.isCompleted) {
          completer.completeError(DesktopSsoException('Sign-in timed out. Please try again.'));
        }
      });

      final sub = server.listen((HttpRequest req) async {
        // Ignore anything that isn't our callback (e.g. a browser favicon probe).
        if (!req.uri.path.startsWith('/callback')) {
          req.response.statusCode = HttpStatus.notFound;
          await req.response.close();
          return;
        }
        final q = req.uri.queryParameters;
        final token = q['token'];
        final gotState = q['state'];
        final err = q['error'];
        final ok = err == null && token != null && token.isNotEmpty && gotState == state;

        req.response.statusCode = HttpStatus.ok;
        req.response.headers.contentType = ContentType.html;
        req.response.write(_resultHtml(ok));
        await req.response.close();

        if (completer.isCompleted) return;
        if (ok) {
          completer.complete(token);
        } else if (err != null) {
          completer.completeError(DesktopSsoException('Sign-in failed: $err'));
        } else if (gotState != state) {
          completer.completeError(DesktopSsoException('Sign-in could not be verified. Please try again.'));
        } else {
          completer.completeError(DesktopSsoException('No token was returned. Please try again.'));
        }
      });

      try {
        return await completer.future;
      } finally {
        timer.cancel();
        await sub.cancel();
      }
    } finally {
      await server.close(force: true);
    }
  }

  static String _resultHtml(bool ok) {
    final title = ok ? 'Signed in to CloudSpace' : 'Sign-in failed';
    final msg = ok
        ? 'You can close this tab and return to the CloudSpace app.'
        : 'Something went wrong. Close this tab and try again from the app.';
    final color = ok ? '#679A41' : '#D14343';
    final icon = ok ? '&#10003;' : '&#10007;';
    return '''
<!doctype html><html><head><meta charset="utf-8"><title>$title</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
  body{margin:0;height:100vh;display:flex;align-items:center;justify-content:center;
       font-family:-apple-system,Segoe UI,Roboto,sans-serif;background:#F8FAFC;color:#0F172A}
  .card{text-align:center;padding:40px 48px;background:#fff;border-radius:16px;
        box-shadow:0 10px 40px rgba(0,0,0,.08);max-width:380px}
  .badge{width:64px;height:64px;border-radius:50%;background:$color;color:#fff;
         display:flex;align-items:center;justify-content:center;font-size:32px;margin:0 auto 20px}
  h1{font-size:20px;margin:0 0 8px} p{font-size:14px;color:#64748B;margin:0;line-height:1.5}
</style></head><body>
  <div class="card"><div class="badge">$icon</div><h1>$title</h1><p>$msg</p></div>
</body></html>''';
  }
}
