import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'config/theme.dart';
import 'services/account_manager.dart';
import 'services/auth_service.dart';
import 'services/data_cache_service.dart';
import 'services/sync_service.dart';
import 'screens/auth/login_screen.dart';
import 'screens/home_shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  HttpOverrides.global = _CloudSpaceHttpOverrides();

  runApp(const CloudSpaceApp());
}

class _CloudSpaceHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback = (X509Certificate cert, String host, int port) {
        return host.contains('worldposta.com');
      };
  }
}

/// Bridge that prefers AccountManager credentials, falls back to AuthService.
class AuthBridge extends AuthService {
  final AccountManager _mgr;
  final AuthService _real;

  AuthBridge(this._mgr, this._real);

  @override
  String? get serverUrl => _mgr.isLoggedIn ? _mgr.serverUrl : _real.serverUrl;
  @override
  String? get username => _mgr.isLoggedIn ? _mgr.username : _real.username;
  @override
  String? get userId => _mgr.isLoggedIn ? _mgr.userId : _real.userId;
  @override
  String? get appPassword => _mgr.isLoggedIn ? _mgr.appPassword : _real.appPassword;
  @override
  String? get displayName => _mgr.isLoggedIn ? _mgr.displayName : _real.displayName;
  @override
  bool get isLoggedIn => _mgr.isLoggedIn || _real.isLoggedIn;
  @override
  bool get isLoading => _real.isLoading;
  @override
  String get basicAuth => _mgr.isLoggedIn ? _mgr.basicAuth : _real.basicAuth;

  // Access the real AuthService's credentials (for after login, before AccountManager is updated)
  String? get realServerUrl => _real.serverUrl;
  String? get realUsername => _real.username;
  String? get realUserId => _real.userId;
  String? get realAppPassword => _real.appPassword;
  String? get realDisplayName => _real.displayName;

  // Delegate login flow methods to the real AuthService
  @override
  Future<LoginFlowResult> initiateLoginFlow({String? serverUrl}) =>
      _real.initiateLoginFlow(serverUrl: serverUrl);
  @override
  Future<bool> pollLoginFlow(LoginFlowResult flow) => _real.pollLoginFlow(flow);
  @override
  Future<bool> loginWithCredentials({required String serverUrl, required String username, required String password}) =>
      _real.loginWithCredentials(serverUrl: serverUrl, username: username, password: password);
  @override
  Future<void> init() => _real.init();
  @override
  Future<void> logout() async {
    await _real.logout();
    if (_mgr.isLoggedIn) {
      await _mgr.logoutCurrent();
    }
  }
}

class CloudSpaceApp extends StatefulWidget {
  const CloudSpaceApp({super.key});

  @override
  State<CloudSpaceApp> createState() => _CloudSpaceAppState();
}

class _CloudSpaceAppState extends State<CloudSpaceApp> {
  final _accountMgr = AccountManager();
  final _authService = AuthService();
  late final AuthBridge _bridge;
  DataCacheService? _cache;
  SyncService? _sync;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _bridge = AuthBridge(_accountMgr, _authService);
    _init();
  }

  Future<void> _init() async {
    await _accountMgr.init();
    await _authService.init();

    debugPrint('Init done: accountMgr.isLoggedIn=${_accountMgr.isLoggedIn} auth.isLoggedIn=${_authService.isLoggedIn}');
    debugPrint('Bridge: serverUrl=${_bridge.serverUrl} username=${_bridge.username} userId=${_bridge.userId}');

    _accountMgr.addListener(_onAuthChanged);
    _authService.addListener(_onAuthChanged);
    _setupServices();
    setState(() => _initialized = true);
  }

  String? _lastActiveAccountId;

  void _onAuthChanged() {
    _setupServices();
    setState(() {});
  }

  void _setupServices() {
    final isLoggedIn = _bridge.isLoggedIn;
    final currentId = _accountMgr.activeAccount?.id;

    if (isLoggedIn && (_cache == null || currentId != _lastActiveAccountId)) {
      // Dispose old services when switching accounts
      _cache?.dispose();
      _sync?.dispose();
      _cache = DataCacheService(_bridge)..init();
      _sync = SyncService(_bridge)..init();
      _lastActiveAccountId = currentId;
    } else if (!isLoggedIn) {
      _cache?.dispose();
      _sync?.dispose();
      _cache = null;
      _sync = null;
      _lastActiveAccountId = null;
    }
  }

  @override
  void dispose() {
    _accountMgr.removeListener(_onAuthChanged);
    _authService.removeListener(_onAuthChanged);
    _cache?.dispose();
    _sync?.dispose();
    _accountMgr.dispose();
    _authService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return const MaterialApp(
        home: Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }

    final isLoggedIn = _bridge.isLoggedIn;

    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: _accountMgr),
        // Provide bridge AS AuthService — all reads get correct active account credentials
        ChangeNotifierProvider<AuthService>.value(value: _bridge),
        if (_cache != null) ChangeNotifierProvider.value(value: _cache!),
        if (_sync != null) ChangeNotifierProvider.value(value: _sync!),
      ],
      child: MaterialApp(
        title: 'CloudSpace',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.lightTheme,
        home: isLoggedIn ? const HomeShell() : const LoginScreen(),
      ),
    );
  }
}
