import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'config/theme.dart';
import 'services/auth_service.dart';
import 'services/data_cache_service.dart';
import 'services/sync_service.dart';
import 'screens/auth/login_screen.dart';
import 'screens/home_shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Allow connections to servers with incomplete SSL certificate chains
  // (e.g. missing intermediate certificates). This is needed for some
  // self-hosted Nextcloud servers.
  HttpOverrides.global = _CloudSpaceHttpOverrides();

  runApp(const CloudSpaceApp());
}

class _CloudSpaceHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback = (X509Certificate cert, String host, int port) {
        // Only trust our server
        return host.contains('worldposta.com');
      };
  }
}

class CloudSpaceApp extends StatelessWidget {
  const CloudSpaceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AuthService()..init(),
      child: Consumer<AuthService>(
        builder: (context, auth, _) {
          return MultiProvider(
            providers: [
              ChangeNotifierProvider.value(value: auth),
              if (auth.isLoggedIn)
                ChangeNotifierProvider(
                  create: (_) => DataCacheService(auth)..init(),
                ),
              if (auth.isLoggedIn)
                ChangeNotifierProvider(
                  create: (_) => SyncService(auth)..init(),
                ),
            ],
            child: MaterialApp(
              title: 'CloudSpace',
              debugShowCheckedModeBanner: false,
              theme: AppTheme.lightTheme,
              home: auth.isLoggedIn ? const HomeShell() : const LoginScreen(),
            ),
          );
        },
      ),
    );
  }
}
