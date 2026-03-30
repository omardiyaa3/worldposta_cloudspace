import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../config/constants.dart';
import '../../config/theme.dart';
import '../../services/auth_service.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _showManualLogin = false;
  bool _isLoading = false;
  String? _error;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _startLoginFlow() async {
    setState(() { _isLoading = true; _error = null; });
    try {
      final auth = context.read<AuthService>();
      final flow = await auth.initiateLoginFlow();
      final uri = Uri.parse(flow.loginUrl);
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      final success = await auth.pollLoginFlow(flow);
      if (success && mounted) {
        // Bring app back to foreground
        try {
          await launchUrl(Uri.parse('cloudspace://login-complete'), mode: LaunchMode.externalApplication);
        } catch (_) {}
      }
      if (!success && mounted) {
        setState(() => _error = 'Login timed out. Please try again.');
      }
    } catch (e) {
      debugPrint('Login flow error: $e');
      if (mounted) setState(() => _error = 'Connection failed: ${e.toString().length > 100 ? e.toString().substring(0, 100) : e}');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _manualLogin() async {
    if (_usernameController.text.isEmpty || _passwordController.text.isEmpty) {
      setState(() => _error = 'Please enter username and password.');
      return;
    }
    setState(() { _isLoading = true; _error = null; });
    try {
      final auth = context.read<AuthService>();
      final success = await auth.loginWithCredentials(
        serverUrl: AppConstants.defaultServerUrl,
        username: _usernameController.text.trim(),
        password: _passwordController.text,
      );
      if (!success && mounted) setState(() => _error = 'Invalid credentials.');
    } catch (e) {
      if (mounted) setState(() => _error = 'Connection failed. Please try again.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isWide = screenWidth > 800;

    return Scaffold(
      backgroundColor: AppColors.grey98,
      body: Row(
        children: [
          // Left panel — branding (only on wide screens)
          if (isWide)
            Expanded(
              flex: 5,
              child: Container(
                color: AppColors.azure17,
                child: Padding(
                  padding: const EdgeInsets.all(48),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Logo row
                      Row(
                        children: [
                          Image.asset('assets/logo.png', width: 44, height: 44),
                          const SizedBox(width: 12),
                          const Text(
                            'CloudSpace',
                            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.white),
                          ),
                        ],
                      ),
                      const Spacer(),
                      // Hero text
                      const Text(
                        'Your files.\nAnywhere.\nAlways in sync.',
                        style: TextStyle(
                          fontSize: 38,
                          fontWeight: FontWeight.w700,
                          color: AppColors.white,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Access, share, and collaborate on your files from any device. Powered by WorldPosta.',
                        style: TextStyle(fontSize: 15, color: AppColors.white.withValues(alpha: 0.6), height: 1.5),
                      ),
                      const SizedBox(height: 32),
                      // Feature pills
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          _FeaturePill(icon: Icons.sync, label: 'Real-time Sync'),
                          _FeaturePill(icon: Icons.lock_outline, label: 'End-to-End Encrypted'),
                          _FeaturePill(icon: Icons.devices, label: 'All Platforms'),
                        ],
                      ),
                      const Spacer(),
                      Text(
                        'worldposta.com/cloudspace',
                        style: TextStyle(fontSize: 13, color: AppColors.white.withValues(alpha: 0.35)),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Right panel — login form
          Expanded(
            flex: isWide ? 4 : 1,
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 380),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Logo (mobile only)
                      if (!isWide) ...[
                        Center(child: Image.asset('assets/logo.png', width: 56, height: 56)),
                        const SizedBox(height: 12),
                        const Center(
                          child: Text('CloudSpace', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.green800)),
                        ),
                        const SizedBox(height: 32),
                      ],

                      const Text(
                        'Welcome back',
                        style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: AppColors.heading),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Sign in to continue to your cloud.',
                        style: TextStyle(fontSize: 14, color: AppColors.body),
                      ),
                      const SizedBox(height: 32),

                      if (_showManualLogin) ...[
                        _buildTextField(_usernameController, 'Username', Icons.person_outline),
                        const SizedBox(height: 14),
                        _buildTextField(_passwordController, 'App Password', Icons.lock_outline, obscure: true, onSubmit: _manualLogin),
                        const SizedBox(height: 24),
                        _buildButton('Sign In', _isLoading ? null : _manualLogin),
                      ] else ...[
                        _buildButton('Get Started', _isLoading ? null : _startLoginFlow),
                        if (_isLoading) ...[
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.green700)),
                              const SizedBox(width: 10),
                              const Text('Waiting for browser login...', style: TextStyle(fontSize: 13, color: AppColors.body)),
                            ],
                          ),
                        ],
                      ],

                      const SizedBox(height: 16),
                      Center(
                        child: TextButton(
                          onPressed: () => setState(() => _showManualLogin = !_showManualLogin),
                          child: Text(
                            _showManualLogin ? 'Use browser login instead' : 'Sign in with app password',
                            style: const TextStyle(color: AppColors.green700, fontSize: 13),
                          ),
                        ),
                      ),

                      if (_error != null) ...[
                        const SizedBox(height: 14),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppColors.filePdf.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.error_outline, color: AppColors.filePdf, size: 18),
                              const SizedBox(width: 8),
                              Expanded(child: Text(_error!, style: const TextStyle(color: AppColors.filePdf, fontSize: 13))),
                            ],
                          ),
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

  Widget _buildTextField(TextEditingController controller, String hint, IconData icon, {bool obscure = false, VoidCallback? onSubmit}) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      onSubmitted: onSubmit != null ? (_) => onSubmit() : null,
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: Icon(icon, size: 20, color: AppColors.muted),
        filled: true,
        fillColor: AppColors.grey96,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppColors.green700, width: 1.5)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
    );
  }

  Widget _buildButton(String label, VoidCallback? onPressed) {
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.green800,
          foregroundColor: AppColors.white,
          disabledBackgroundColor: AppColors.green800.withValues(alpha: 0.6),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          elevation: 0,
        ),
        child: Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      ),
    );
  }
}

class _FeaturePill extends StatelessWidget {
  final IconData icon;
  final String label;
  const _FeaturePill({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.white.withValues(alpha: 0.15)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: AppColors.green500),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(fontSize: 12, color: AppColors.white.withValues(alpha: 0.8), fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}
