// drive_login_screen.dart — sign-in for the WorldPosta Drive.
//
// iPhone, iPad and Mac: a native email + password form (plus the emailed code
// when the account needs one) against the SSO's mobile endpoints — see
// DriveSsoPasswordLogin. The app never shows the SSO's web sign-in page, which
// also carries a business sign-up link the App Store doesn't allow (3.1.1).
// A server in Active Directory mode still gets its own web sign-in page.
// Windows: the system browser + loopback redirect (DriveDesktopSso).
// Advanced: paste a `dk_` API token minted in the web UI (Settings → Security);
// we validate it against GET /me via DriveAccountManager and store it in the
// OS keystore — every sign-in path ends there.

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config/drive_constants.dart';
import '../../config/theme.dart';
import '../../services/drive/drive_account_manager.dart';
import '../../services/drive/drive_auth_mode.dart';
import '../../services/drive/drive_client.dart';
import '../../services/drive/drive_desktop_sso.dart';
import '../../services/drive/drive_sso_password_login.dart';
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
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _codeController = TextEditingController();
  bool _busy = false;
  bool _hidePassword = true;
  /// Set once the SSO has emailed a code: the address it went to.
  String? _codeSentTo;

  // Windows keeps the browser sign-in; everywhere else signs in natively.
  bool get _native => !Platform.isWindows;
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
    _emailController.dispose();
    _passwordController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  /// Native sign-in, step 1: email + password (also "Send a new code").
  Future<void> _passwordSignIn() async {
    final server = _serverController.text.trim();
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (server.isEmpty) return setState(() => _error = 'Enter your Drive server URL.');
    if (email.isEmpty || password.isEmpty) return setState(() => _error = 'Enter your email and password.');
    setState(() {
      _busy = true;
      _error = null;
    });
    final sso = DriveSsoPasswordLogin();
    try {
      final mode = await DriveAuthModeProbe.fetch(server);
      if (!mounted) return;
      if (mode == DriveAuthMode.unavailable) {
        return setState(() => _error = "Can't reach the Drive server. Check your connection and try again.");
      }
      if (mode == DriveAuthMode.ad) {
        // An Active Directory server signs in on its own page, not the SSO.
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => DriveSsoLoginScreen(serverUrl: server, onSignedIn: widget.onSignedIn),
        ));
        return;
      }
      await _finish(sso, server, await sso.login(email, password));
    } on SsoSignInException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on DriveException catch (e) {
      if (mounted) setState(() => _error = 'Sign-in failed: ${e.message}');
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not complete sign-in. Please try again.');
    } finally {
      sso.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Native sign-in, step 2: the emailed code.
  Future<void> _verifyCode() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) return setState(() => _error = 'Enter the code from the email.');
    setState(() {
      _busy = true;
      _error = null;
    });
    final sso = DriveSsoPasswordLogin();
    try {
      await _finish(sso, _serverController.text.trim(),
          await sso.verifyCode(_codeSentTo ?? _emailController.text, _passwordController.text, code));
    } on SsoSignInException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on DriveException catch (e) {
      if (mounted) setState(() => _error = 'Sign-in failed: ${e.message}');
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not complete sign-in. Please try again.');
    } finally {
      sso.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Signed in at the SSO → Drive token → stored account. Or show the code step.
  Future<void> _finish(DriveSsoPasswordLogin sso, String server, SsoSignInStep step) async {
    switch (step) {
      case SsoCodeRequired(:final email):
        _codeController.clear();
        if (mounted) setState(() => _codeSentTo = email);
      case SsoSignedIn(:final accessToken):
        final token = await sso.mintDriveToken(server, accessToken);
        if (!mounted) return;
        await context.read<DriveAccountManager>().addAccountFromToken(serverUrl: server, token: token);
        _passwordController.clear();
        if (mounted) widget.onSignedIn?.call();
    }
  }

  void _backToPassword() => setState(() {
        _codeSentTo = null;
        _codeController.clear();
        _error = null;
      });

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

  InputDecoration _field(String label, IconData icon, {Widget? suffix}) => InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, size: 20, color: AppColors.muted),
        suffixIcon: suffix,
        filled: true,
        fillColor: AppColors.grey96,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppColors.green700, width: 1.5)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      );

  Widget _primaryButton(String label, VoidCallback onPressed) => SizedBox(
        width: double.infinity,
        height: 48,
        child: ElevatedButton(
          onPressed: _busy ? null : onPressed,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.green700,
            foregroundColor: AppColors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            elevation: 0,
          ),
          child: _busy
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.white))
              : Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        ),
      );

  /// Email + password, then (if the SSO asks) the emailed code.
  Widget _nativeForm() {
    if (_codeSentTo != null) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('We emailed a verification code to $_codeSentTo. Enter it to finish signing in.',
            style: const TextStyle(fontSize: 14, color: AppColors.body, height: 1.4)),
        const SizedBox(height: 14),
        TextField(
          controller: _codeController,
          autofocus: true,
          keyboardType: TextInputType.number,
          autofillHints: const [AutofillHints.oneTimeCode],
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _busy ? null : _verifyCode(),
          decoration: _field('Verification code', Icons.pin_outlined),
        ),
        const SizedBox(height: 14),
        _primaryButton('Verify', _verifyCode),
        const SizedBox(height: 6),
        Wrap(spacing: 16, children: [
          TextButton(
            onPressed: _busy ? null : _passwordSignIn,
            style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 36)),
            child: const Text('Send a new code', style: TextStyle(color: AppColors.green700, fontSize: 13)),
          ),
          TextButton(
            onPressed: _busy ? null : _backToPassword,
            style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 36)),
            child: const Text('Use a different account', style: TextStyle(color: AppColors.muted, fontSize: 13)),
          ),
        ]),
      ]);
    }
    return AutofillGroup(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(
          controller: _emailController,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          enableSuggestions: false,
          autofillHints: const [AutofillHints.username, AutofillHints.email],
          textInputAction: TextInputAction.next,
          decoration: _field('Work email', Icons.mail_outline),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _passwordController,
          obscureText: _hidePassword,
          autocorrect: false,
          enableSuggestions: false,
          autofillHints: const [AutofillHints.password],
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _busy ? null : _passwordSignIn(),
          decoration: _field('Password', Icons.lock_outline,
              suffix: IconButton(
                icon: Icon(_hidePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                    size: 20, color: AppColors.muted),
                tooltip: _hidePassword ? 'Show password' : 'Hide password',
                onPressed: () => setState(() => _hidePassword = !_hidePassword),
              )),
        ),
        const SizedBox(height: 16),
        _primaryButton('Sign in', _passwordSignIn),
        const SizedBox(height: 10),
        const Text('Forgot your password? Ask your organization\'s administrator to reset it.',
            style: TextStyle(fontSize: 13, color: AppColors.muted)),
      ]),
    );
  }

  Future<void> _pasteToken() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) {
      _tokenController.text = data!.text!.trim();
      setState(() {});
    }
  }

  Future<void> _openPage(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  Widget _pageLink(String label, String url) => TextButton(
        onPressed: () => _openPage(url),
        style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 32)),
        child: Text(label, style: const TextStyle(color: AppColors.muted, fontSize: 13)),
      );

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width > 800;
    return Scaffold(
      backgroundColor: AppColors.page,
      body: Row(
        children: [
          if (isWide)
            Expanded(
              flex: 5,
              // Same brand panel as the web sign-in page (ADLogin.tsx).
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF1D2A6B), Color(0xFF293C51), Color(0xFF3D6B1F)],
                    stops: [0, 0.45, 1],
                  ),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 56, vertical: 48),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Image.asset('assets/logo.png', width: 52, height: 52),
                      const SizedBox(width: 12),
                      const Text('Posta Drive',
                          style: TextStyle(
                              fontFamily: 'PublicSans', fontSize: 24, fontWeight: FontWeight.w700, color: AppColors.white)),
                    ]),
                    const Spacer(),
                    const Text('Your work files, safe and always with you.',
                        style: TextStyle(
                            fontFamily: 'PublicSans',
                            fontSize: 34,
                            fontWeight: FontWeight.w700,
                            color: AppColors.white,
                            height: 1.2,
                            letterSpacing: -0.4)),
                    const SizedBox(height: 28),
                    for (final h in const [
                      ('All your files, one place', 'Upload, organise and find anything in seconds.'),
                      ('Work together', 'Share with colleagues or outside partners, with the access you choose.'),
                      ('Edit Office documents', 'Word, Excel and PowerPoint, right in the app.'),
                    ]) ...[
                      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Container(
                          width: 26,
                          height: 26,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                              color: AppColors.white.withValues(alpha: 0.14), shape: BoxShape.circle),
                          child: const Icon(Icons.check, size: 15, color: AppColors.green500),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(h.$1,
                                style: const TextStyle(
                                    fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.white)),
                            const SizedBox(height: 2),
                            Text(h.$2,
                                style: TextStyle(
                                    fontSize: 14, color: AppColors.white.withValues(alpha: 0.78), height: 1.45)),
                          ]),
                        ),
                      ]),
                      const SizedBox(height: 18),
                    ],
                    const Spacer(),
                    Text('Posta Drive by WorldPosta',
                        style: TextStyle(fontSize: 13, color: AppColors.white.withValues(alpha: 0.55))),
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
                            child: Text('Posta Drive',
                                style: TextStyle(
                                    fontFamily: 'PublicSans',
                                    fontSize: 22,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.heading))),
                        const SizedBox(height: 32),
                      ],
                      const Text('Sign in',
                          style: TextStyle(
                              fontFamily: 'PublicSans', fontSize: 26, fontWeight: FontWeight.w700, color: AppColors.heading)),
                      const SizedBox(height: 6),
                      const Text('Sign in with your work account.',
                          style: TextStyle(fontSize: 14, color: AppColors.body)),
                      const SizedBox(height: 24),

                      // Primary: native sign-in (Windows: the browser)
                      if (_native) _nativeForm() else SizedBox(
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
                        Wrap(
                          alignment: WrapAlignment.spaceBetween,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 12,
                          runSpacing: 8,
                          children: [
                          // Text, not a link: signed out, the Drive website forwards to
                          // the SSO page, whose sign-up link App Review rejects (3.1.1).
                          const Text('Create one on the Posta Drive website:\nSettings → Security & API tokens.',
                              style: TextStyle(color: AppColors.muted, fontSize: 13)),
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
                      const SizedBox(height: 20),
                      Wrap(spacing: 16, children: [
                        _pageLink('Privacy policy', DriveConstants.privacyUrl),
                        _pageLink('Support', DriveConstants.supportUrl),
                      ]),
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
