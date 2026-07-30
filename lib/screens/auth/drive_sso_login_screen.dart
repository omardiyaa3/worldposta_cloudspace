// drive_sso_login_screen.dart — embedded WorldPosta SSO login.
//
// Opens the SSO login page DIRECTLY (ssotest.worldposta.com/auth/login?return_to=
// <drive>) — the same redirect the Drive SPA does — so the login appears fast
// without loading the Drive SPA first. The webview is INCOGNITO (private session),
// so no cookies carry over between logins: each sign-in starts fresh, which is
// what makes adding / switching accounts work.
//
// The user signs in with username/password (and 2FA if enabled). The SSO redirects
// back to the Drive origin with the session cookie set, and we mint a `dk_` API
// token via POST /api/v1/me/tokens (same-origin fetch → cookie auth). That token
// is captured, validated, and stored — exactly like a pasted token, so the rest of
// the app is unchanged.

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:provider/provider.dart';

import '../../config/drive_constants.dart';
import '../../config/theme.dart';
import '../../services/drive/drive_account_manager.dart';
import '../../services/drive/drive_client.dart';

class DriveSsoLoginScreen extends StatefulWidget {
  final String serverUrl; // Drive base, e.g. https://portal.worldposta.com:2023
  final VoidCallback? onSignedIn;
  const DriveSsoLoginScreen({super.key, required this.serverUrl, this.onSignedIn});

  @override
  State<DriveSsoLoginScreen> createState() => _DriveSsoLoginScreenState();
}

class _DriveSsoLoginScreenState extends State<DriveSsoLoginScreen> {
  bool _finishing = false;
  bool _loading = true; // until the SSO page first renders
  String? _error;

  String get _base {
    final s = widget.serverUrl.trim();
    return s.endsWith('/') ? s.substring(0, s.length - 1) : s;
  }

  Uri get _baseUri => Uri.parse(_base);

  /// Open the SSO login page DIRECTLY (with a return_to back to the Drive) rather
  /// than loading the Drive SPA first and waiting for it to redirect — much faster.
  /// Matches the redirect the Drive SPA itself performs.
  String get _ssoLoginUrl {
    final returnTo = Uri.encodeComponent('$_base/');
    return '${DriveConstants.ssoAuthUrl}/login?return_to=$returnTo';
  }

  // Runs on the Drive origin: try to mint a token; if it works, hand it back.
  static const _mintJs = '''
(async () => {
  try {
    const r = await fetch('/api/v1/me/tokens', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'same-origin',
      body: JSON.stringify({ name: 'CloudSpace Desktop', scopes: ['clouddrive:write'] })
    });
    if (r.ok) {
      const j = await r.json();
      if (j && j.data && j.data.token) window.flutter_inappwebview.callHandler('onToken', j.data.token);
    }
  } catch (e) {}
})();
''';

  Future<void> _onToken(String token) async {
    if (_finishing || token.isEmpty || !token.startsWith('dk_')) return;
    _finishing = true;
    setState(() {});
    try {
      final mgr = context.read<DriveAccountManager>();
      await mgr.addAccountFromToken(serverUrl: _base, token: token);
      if (mounted) {
        // Adding an account: onSignedIn pops ALL auth routes back to home. Don't
        // ALSO maybePop here (that's the racy double-pop that stranded the user on
        // the login page). Only pop ourselves for the initial login (no callback).
        if (widget.onSignedIn != null) {
          widget.onSignedIn!();
        } else {
          Navigator.of(context).maybePop();
        }
      }
    } on DriveException catch (e) {
      if (mounted) setState(() { _finishing = false; _error = 'Signed in, but validating the token failed: ${e.message}'; });
    } catch (e) {
      if (mounted) setState(() { _finishing = false; _error = 'Could not complete sign-in: $e'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.white,
      appBar: AppBar(
        title: const Text('Sign in to WorldPosta', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        backgroundColor: AppColors.white,
        foregroundColor: AppColors.heading,
        elevation: 0,
        leading: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).maybePop()),
      ),
      body: Column(children: [
        if (_error != null)
          Container(
            width: double.infinity,
            color: AppColors.filePdf.withValues(alpha: 0.08),
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              const Icon(Icons.error_outline, color: AppColors.filePdf, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text(_error!, style: const TextStyle(color: AppColors.filePdf, fontSize: 13))),
            ]),
          ),
        Expanded(
          child: Stack(children: [
            inapp.InAppWebView(
              initialUrlRequest: inapp.URLRequest(url: inapp.WebUri(_ssoLoginUrl)),
              initialSettings: inapp.InAppWebViewSettings(
                javaScriptEnabled: true,
                javaScriptCanOpenWindowsAutomatically: true,
                // Private session: no cookies carried over from a previous login,
                // so each sign-in starts fresh — enables switching / adding accounts.
                incognito: true,
                clearCache: true,
              ),
              onWebViewCreated: (controller) {
                controller.addJavaScriptHandler(
                  handlerName: 'onToken',
                  callback: (args) {
                    if (args.isNotEmpty && args.first is String) _onToken(args.first as String);
                    return null;
                  },
                );
              },
              // Accept the Drive's self-signed cert (*.worldposta.com).
              onReceivedServerTrustAuthRequest: (controller, challenge) async =>
                  inapp.ServerTrustAuthResponse(action: inapp.ServerTrustAuthResponseAction.PROCEED),
              onLoadStop: (controller, url) async {
                if (_loading && mounted) setState(() => _loading = false);
                if (url == null || _finishing) return;
                // Only attempt minting once we're back on the Drive's own origin
                // (i.e. the SSO round-trip completed and the session cookie is set).
                if (url.host == _baseUri.host) {
                  await controller.evaluateJavascript(source: _mintJs);
                }
              },
            ),
            if (_loading && !_finishing)
              const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                CircularProgressIndicator(color: AppColors.green700),
                SizedBox(height: 16),
                Text('Loading sign-in…', style: TextStyle(color: AppColors.body)),
              ])),
            if (_finishing)
              Container(
                color: AppColors.white.withValues(alpha: 0.9),
                child: const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  CircularProgressIndicator(color: AppColors.green700),
                  SizedBox(height: 16),
                  Text('Finishing sign-in…', style: TextStyle(color: AppColors.body)),
                ])),
              ),
          ]),
        ),
      ]),
    );
  }
}
