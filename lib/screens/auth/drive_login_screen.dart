// drive_login_screen.dart — token-paste sign-in for the WorldPosta Drive.
//
// The Drive has no password/OAuth endpoint of its own; the only native
// credential is a `dk_` API token minted in the web UI (Settings → Security).
// The user pastes it here; we validate it against GET /me via
// DriveAccountManager and store it in the OS keystore.

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config/drive_constants.dart';
import '../../config/theme.dart';
import '../../services/drive/drive_account_manager.dart';
import '../../services/drive/drive_client.dart';
import '../../services/drive/drive_desktop_sso.dart';
import 'drive_sso_login_screen.dart';

class DriveLoginScreen extends StatefulWidget {
  /// Called after a successful sign-in (e.g. to pop when adding an account).
  final VoidCallback? onSignedIn;
  const DriveLoginScreen({super.key, this.onSignedIn});

  @override
  State<DriveLoginScreen> createState() => _DriveLoginScreenState();
}

class _DriveLoginScreenState extends State<DriveLoginScreen> {
  final _serverController = TextEditingController(text: DriveConstants.defaultServerUrl);
  final _tokenController = TextEditingController();
  bool _busy = false;
  bool _showServer = false;
  bool _showToken = false;
  String? _error;

  Future<void> _ssoLogin() async {
    final server = _serverController.text.trim();
    if (server.isEmpty) {
      setState(() => _error = 'Enter your Drive server URL.');
      return;
    }
    // Windows: embedded webviews (WebView2) are unreliable, so sign in through
    // the user's real browser + a loopback redirect. macOS/other keep the fast
    // embedded webview, which works well there.
    if (!Platform.isWindows) {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => DriveSsoLoginScreen(serverUrl: server, onSignedIn: widget.onSignedIn),
      ));
      return;
    }
    final mgr = context.read<DriveAccountManager>();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final token = await DriveDesktopSso.signIn(server);
      await mgr.addAccountFromToken(serverUrl: server, token: token);
      if (mounted) widget.onSignedIn?.call();
    } on DesktopSsoException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on DriveException catch (e) {
      if (mounted) {
        setState(() => _error = e.isAuth
            ? 'Sign-in was rejected by the server. Please try again.'
            : 'Sign-in failed: ${e.message}');
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not complete sign-in. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _serverController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    final server = _serverController.text.trim();
    final token = _tokenController.text.trim();
    if (server.isEmpty) {
      setState(() => _error = 'Enter your Drive server URL.');
      return;
    }
    if (token.isEmpty) {
      setState(() => _error = 'Paste your access token.');
      return;
    }
    if (!token.startsWith('dk_')) {
      setState(() => _error = 'That doesn\'t look like a Drive access token (should start with "dk_").');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final mgr = context.read<DriveAccountManager>();
      await mgr.addAccountFromToken(serverUrl: server, token: token);
      if (mounted) widget.onSignedIn?.call();
    } on DriveException catch (e) {
      if (mounted) {
        setState(() => _error = e.isAuth
            ? 'That token was rejected. Mint a fresh one in the Drive web app and try again.'
            : 'Sign-in failed: ${e.message}');
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not reach the server. Check the URL and your connection.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pasteToken() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) {
      _tokenController.text = data!.text!.trim();
      setState(() {});
    }
  }

  Future<void> _openTokenHelp() async {
    var base = _serverController.text.trim();
    if (base.isEmpty) base = DriveConstants.defaultServerUrl;
    if (base.endsWith('/')) base = base.substring(0, base.length - 1);
    final uri = Uri.parse('$base${DriveConstants.tokenHelpPath}');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width > 800;
    return Scaffold(
      backgroundColor: AppColors.grey98,
      body: Row(
        children: [
          if (isWide)
            Expanded(
              flex: 5,
              child: Container(
                color: AppColors.azure17,
                padding: const EdgeInsets.all(48),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Image.asset('assets/logo.png', width: 44, height: 44),
                      const SizedBox(width: 12),
                      const Text('CloudSpace',
                          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.white)),
                    ]),
                    const Spacer(),
                    const Text('Your files.\nAnywhere.\nAlways in sync.',
                        style: TextStyle(
                            fontSize: 38, fontWeight: FontWeight.w700, color: AppColors.white, height: 1.2)),
                    const SizedBox(height: 16),
                    Text('Access, share, and collaborate on your files from any device. Powered by WorldPosta.',
                        style: TextStyle(fontSize: 15, color: AppColors.white.withValues(alpha: 0.6), height: 1.5)),
                    const Spacer(),
                    Text('worldposta.com',
                        style: TextStyle(fontSize: 13, color: AppColors.white.withValues(alpha: 0.35))),
                  ],
                ),
              ),
            ),
          Expanded(
            flex: isWide ? 4 : 1,
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 400),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (!isWide) ...[
                        Center(child: Image.asset('assets/logo.png', width: 56, height: 56)),
                        const SizedBox(height: 12),
                        const Center(
                            child: Text('CloudSpace',
                                style:
                                    TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.green800))),
                        const SizedBox(height: 32),
                      ],
                      const Text('Welcome back',
                          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: AppColors.heading)),
                      const SizedBox(height: 6),
                      const Text('Sign in with your work account.',
                          style: TextStyle(fontSize: 14, color: AppColors.body)),
                      const SizedBox(height: 24),

                      // Primary: SSO login
                      SizedBox(
                        width: double.infinity,
                        height: 48,
                        child: ElevatedButton.icon(
                          onPressed: _busy ? null : _ssoLogin,
                          icon: const Icon(Icons.login, size: 20),
                          label: const Text('Sign in',
                              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.green700,
                            foregroundColor: AppColors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            elevation: 0,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),

                      // Server override
                      if (_showServer) ...[
                        TextField(
                          controller: _serverController,
                          keyboardType: TextInputType.url,
                          decoration: InputDecoration(
                            labelText: 'Drive server',
                            prefixIcon: const Icon(Icons.dns_outlined, size: 20, color: AppColors.muted),
                            filled: true,
                            fillColor: AppColors.grey96,
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                          ),
                        ),
                        const SizedBox(height: 8),
                      ] else
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            onPressed: () => setState(() => _showServer = true),
                            style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 0)),
                            child: const Text('Use a different server', style: TextStyle(color: AppColors.muted, fontSize: 13)),
                          ),
                        ),

                      // Advanced: paste a token
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: () => setState(() => _showToken = !_showToken),
                          style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 0)),
                          child: Text(_showToken ? 'Hide access-token sign-in' : 'Advanced: use an access token',
                              style: const TextStyle(color: AppColors.muted, fontSize: 13)),
                        ),
                      ),
                      if (_showToken) ...[
                        const SizedBox(height: 8),
                        TextField(
                          controller: _tokenController,
                          obscureText: true,
                          enableSuggestions: false,
                          autocorrect: false,
                          onSubmitted: (_) => _busy ? null : _signIn(),
                          decoration: InputDecoration(
                            hintText: 'dk_…  (access token)',
                            prefixIcon: const Icon(Icons.key_outlined, size: 20, color: AppColors.muted),
                            suffixIcon: IconButton(
                              icon: const Icon(Icons.content_paste, size: 18, color: AppColors.muted),
                              tooltip: 'Paste',
                              onPressed: _pasteToken,
                            ),
                            filled: true,
                            fillColor: AppColors.grey96,
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppColors.green700, width: 1.5)),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(children: [
                          TextButton.icon(
                            onPressed: _openTokenHelp,
                            icon: const Icon(Icons.open_in_new, size: 15, color: AppColors.green700),
                            label: const Text('Where do I get a token?', style: TextStyle(color: AppColors.green700, fontSize: 13)),
                            style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 0)),
                          ),
                          const Spacer(),
                          ElevatedButton(
                            onPressed: _busy ? null : _signIn,
                            child: _busy
                                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.white))
                                : const Text('Sign in with token'),
                          ),
                        ]),
                      ],

                      if (_error != null) ...[
                        const SizedBox(height: 14),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppColors.filePdf.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(children: [
                            const Icon(Icons.error_outline, color: AppColors.filePdf, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                                child: Text(_error!,
                                    style: const TextStyle(color: AppColors.filePdf, fontSize: 13))),
                          ]),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
