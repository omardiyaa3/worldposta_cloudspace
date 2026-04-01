import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'config/theme.dart';
import 'services/account_manager.dart';
import 'services/auth_service.dart';
import 'services/data_cache_service.dart';
import 'services/sync_service.dart';
import 'screens/auth/login_screen.dart';
import 'screens/home_shell.dart';

final bool _isDesktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;

bool _startMinimized = false;

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  HttpOverrides.global = _CloudSpaceHttpOverrides();

  _startMinimized = args.contains('--minimized');

  if (_isDesktop) {
    await windowManager.ensureInitialized();
    const windowOptions = WindowOptions(
      size: Size(1100, 750),
      minimumSize: Size(400, 300),
      title: 'CloudSpace',
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.setPreventClose(true);
      if (_startMinimized) {
        await windowManager.hide();
      } else {
        await windowManager.show();
        await windowManager.focus();
      }
    });
  }

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

class _CloudSpaceAppState extends State<CloudSpaceApp> with TrayListener, WindowListener {
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
    if (_isDesktop) {
      trayManager.addListener(this);
      windowManager.addListener(this);
    }
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
    if (_isDesktop) await _initTray();
    setState(() => _initialized = true);
  }

  Future<String> _resolveTrayIcon() async {
    try {
      final byteData = await rootBundle.load('assets/logo.png');
      final tempDir = await getTemporaryDirectory();
      final ext = Platform.isWindows ? 'ico' : 'png';
      final iconFile = File('${tempDir.path}/cloudspace_tray.$ext');
      if (Platform.isWindows) {
        // Create a minimal .ico from the PNG data
        final pngBytes = byteData.buffer.asUint8List();
        final icoBytes = _pngToIco(pngBytes);
        await iconFile.writeAsBytes(icoBytes);
      } else {
        await iconFile.writeAsBytes(byteData.buffer.asUint8List());
      }
      debugPrint('Tray icon written to: ${iconFile.path}');
      return iconFile.path;
    } catch (e) {
      debugPrint('Failed to resolve tray icon: $e');
      return 'assets/logo.png';
    }
  }

  /// Wrap a PNG in a minimal ICO container for Windows tray.
  List<int> _pngToIco(List<int> pngBytes) {
    final size = pngBytes.length;
    // ICO header: 6 bytes
    // ICO dir entry: 16 bytes
    // Then the PNG data
    final ico = <int>[];
    // Header: reserved=0, type=1(icon), count=1
    ico.addAll([0, 0, 1, 0, 1, 0]);
    // Dir entry: width=0(256), height=0(256), colors=0, reserved=0
    ico.addAll([0, 0, 0, 0]);
    // Planes=1 (little-endian 16-bit)
    ico.addAll([1, 0]);
    // Bits per pixel=32 (little-endian 16-bit)
    ico.addAll([32, 0]);
    // Size of PNG data (little-endian 32-bit)
    ico.add(size & 0xFF);
    ico.add((size >> 8) & 0xFF);
    ico.add((size >> 16) & 0xFF);
    ico.add((size >> 24) & 0xFF);
    // Offset to PNG data = 6 + 16 = 22 (little-endian 32-bit)
    ico.addAll([22, 0, 0, 0]);
    // PNG data
    ico.addAll(pngBytes);
    return ico;
  }

  Future<void> _initTray() async {
    try {
      final iconPath = await _resolveTrayIcon();
      // isTemplate: false — show the actual colored logo, not a monochrome silhouette
      await trayManager.setIcon(iconPath, isTemplate: false);
      await trayManager.setToolTip('CloudSpace — Syncing your files');
      final menu = Menu(items: [
        MenuItem(label: 'Show CloudSpace', onClick: (_) async {
          await windowManager.show();
          await windowManager.focus();
        }),
        MenuItem.separator(),
        MenuItem(label: 'Quit', onClick: (_) async {
          await trayManager.destroy();
          await windowManager.setPreventClose(false);
          await windowManager.close();
        }),
      ]);
      await trayManager.setContextMenu(menu);
      debugPrint('Tray initialized successfully');
    } catch (e) {
      debugPrint('Failed to initialize tray: $e');
    }
  }

  // Tray icon clicked → show window
  @override
  void onTrayIconMouseDown() async {
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onTrayIconRightMouseDown() async {
    await trayManager.popUpContextMenu();
  }

  // Window close → hide to tray instead of quitting
  @override
  void onWindowClose() async {
    await windowManager.hide();
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
    if (_isDesktop) {
      trayManager.removeListener(this);
      windowManager.removeListener(this);
    }
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
        // Key forces full rebuild when account switches, so all widgets pick up new providers
        home: isLoggedIn
            ? HomeShell(key: ValueKey(_lastActiveAccountId))
            : const LoginScreen(),
      ),
    );
  }
}
