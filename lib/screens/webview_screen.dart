import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../config/theme.dart';
import '../services/auth_service.dart';

/// Opens Nextcloud apps in the system browser (Talk, Calendar, Tasks).
/// The Flutter macOS WebView doesn't support keyboard input, so we use
/// the real browser for the best experience.
class NextcloudWebView extends StatefulWidget {
  final String appPath;
  final String title;

  const NextcloudWebView({
    super.key,
    required this.appPath,
    required this.title,
  });

  @override
  State<NextcloudWebView> createState() => _NextcloudWebViewState();
}

class _NextcloudWebViewState extends State<NextcloudWebView> {
  @override
  void initState() {
    super.initState();
    // Auto-open on first load
    _openInBrowser();
  }

  Future<void> _openInBrowser() async {
    final auth = context.read<AuthService>();
    // Embed credentials in URL for auto-login
    final uri = Uri.parse('${auth.serverUrl}${widget.appPath}');
    final authedUri = uri.replace(
      userInfo: '${Uri.encodeComponent(auth.username!)}:${Uri.encodeComponent(auth.appPassword!)}',
    );
    await launchUrl(authedUri, mode: LaunchMode.externalApplication);
  }

  IconData get _icon {
    switch (widget.title) {
      case 'Talk': return Icons.chat_bubble_outline;
      case 'Calendar': return Icons.calendar_today_outlined;
      default: return Icons.check_circle_outline;
    }
  }

  String get _description {
    switch (widget.title) {
      case 'Talk': return 'Chat, video calls, and screen sharing with your team.';
      case 'Calendar': return 'Manage your events, meetings, and schedules.';
      default: return 'Track your tasks and to-dos.';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 400),
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AppColors.greenActiveBg,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(_icon, size: 36, color: AppColors.green800),
            ),
            const SizedBox(height: 20),
            Text(
              widget.title,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.heading),
            ),
            const SizedBox(height: 8),
            Text(
              _description,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: AppColors.body, height: 1.5),
            ),
            const SizedBox(height: 8),
            Text(
              'Opens in your browser for the best experience.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: AppColors.muted),
            ),
            const SizedBox(height: 28),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                onPressed: _openInBrowser,
                icon: const Icon(Icons.open_in_new, size: 18),
                label: Text('Open ${widget.title}'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.green800,
                  foregroundColor: AppColors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  elevation: 0,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
