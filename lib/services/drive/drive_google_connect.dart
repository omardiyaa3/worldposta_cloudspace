// drive_google_connect.dart — connect Google Drive and pick files from the app.
//
// The server hands out a one-time page (POST /imports/google/app-link) that
// connects Google if needed and opens Google's own picker, then sends the
// browser back to the app with ?status=picked|connected|cancelled|error.
//
// Google refuses sign-in inside embedded web views, so the page opens in the
// system's sign-in sheet: ASWebAuthenticationSession on iPhone, iPad and Mac,
// an Auth Tab / Custom Tab on Android (callback postadrive://google), and on
// Windows and Linux the default browser with a loopback callback
// (http://127.0.0.1:<port>/google) — the same pattern as desktop sign-in.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:url_launcher/url_launcher.dart';

import 'drive_api.dart';

enum GoogleConnectStatus { picked, connected, cancelled, error }

class GoogleConnectResult {
  final GoogleConnectStatus status;
  final int count; // items picked (picked only)
  const GoogleConnectResult(this.status, [this.count = 0]);

  static GoogleConnectResult fromCallback(Uri u) {
    final s = u.queryParameters['status'];
    final n = int.tryParse(u.queryParameters['count'] ?? '') ?? 0;
    return switch (s) {
      'picked' => GoogleConnectResult(GoogleConnectStatus.picked, n),
      'connected' => const GoogleConnectResult(GoogleConnectStatus.connected),
      'cancelled' => const GoogleConnectResult(GoogleConnectStatus.cancelled),
      _ => const GoogleConnectResult(GoogleConnectStatus.error),
    };
  }
}

class DriveGoogleConnect {
  static const _scheme = 'postadrive';
  static bool get _loopback => Platform.isWindows || Platform.isLinux;

  /// Runs the whole flow and says how it ended.
  static Future<GoogleConnectResult> run(DriveApi api, String serverUrl) async {
    final base = serverUrl.endsWith('/') ? serverUrl.substring(0, serverUrl.length - 1) : serverUrl;
    if (_loopback) return _viaBrowser(api, base);
    final path = await api.googleAppLink('$_scheme://google');
    try {
      final result = await FlutterWebAuth2.authenticate(
        url: '$base$path',
        callbackUrlScheme: _scheme,
        // Share the browser's cookies: Google remembers the signed-in account.
        options: const FlutterWebAuth2Options(preferEphemeral: false),
      );
      return GoogleConnectResult.fromCallback(Uri.parse(result));
    } on PlatformException catch (e) {
      if (e.code == 'CANCELED') return const GoogleConnectResult(GoogleConnectStatus.cancelled);
      rethrow;
    }
  }

  static Future<GoogleConnectResult> _viaBrowser(DriveApi api, String base) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    try {
      final path = await api.googleAppLink('http://127.0.0.1:${server.port}/google');
      final done = Completer<GoogleConnectResult>();
      final sub = server.listen((req) async {
        if (req.uri.path != '/google') {
          req.response.statusCode = HttpStatus.notFound;
          await req.response.close();
          return;
        }
        final r = GoogleConnectResult.fromCallback(req.uri);
        req.response.headers.contentType = ContentType.html;
        req.response.write(_donePage(r.status != GoogleConnectStatus.error));
        await req.response.close();
        if (!done.isCompleted) done.complete(r);
      });
      if (!await launchUrl(Uri.parse('$base$path'), mode: LaunchMode.externalApplication)) {
        await sub.cancel();
        return const GoogleConnectResult(GoogleConnectStatus.error);
      }
      try {
        return await done.future.timeout(const Duration(minutes: 15),
            onTimeout: () => const GoogleConnectResult(GoogleConnectStatus.cancelled));
      } finally {
        await sub.cancel();
      }
    } finally {
      await server.close(force: true);
    }
  }

  static String _donePage(bool ok) => '''<!doctype html><html><head><meta charset="utf-8"><title>Posta Drive</title>
<style>body{margin:0;height:100vh;display:flex;align-items:center;justify-content:center;font-family:Segoe UI,Roboto,sans-serif;background:#F8FAFC;color:#0F172A}
.c{text-align:center;padding:40px 48px;background:#fff;border-radius:16px;box-shadow:0 4px 24px rgba(15,23,42,.08)}</style></head>
<body><div class="c"><h2>${ok ? 'All set' : 'Something went wrong'}</h2>
<p>${ok ? 'You can close this tab and go back to Posta Drive.' : 'Close this tab and try again from Posta Drive.'}</p></div></body></html>''';
}
