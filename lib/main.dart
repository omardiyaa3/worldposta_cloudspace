import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'config/theme.dart';
import 'services/drive/drive_account_manager.dart';
import 'services/drive/drive_account_stores.dart';
import 'services/drive/drive_cache.dart';
import 'services/drive/drive_sync_service.dart';
import 'screens/auth/drive_login_screen.dart';
import 'screens/drive/drive_home_shell.dart';

final bool _isDesktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;
bool _startMinimized = false;

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = _CloudSpaceHttpOverrides();
  _startMinimized = args.contains('--minimized');

  if (_isDesktop) {
    await windowManager.ensureInitialized();
    const windowOptions = WindowOptions(size: Size(1100, 750), minimumSize: Size(400, 300), title: 'Posta Drive');
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

/// Debug builds only: accept a self-signed certificate on WorldPosta dev hosts.
/// Release builds always verify TLS — production has a public certificate, and
/// the old "host contains worldposta.com" rule also matched look-alike hosts
/// (e.g. evil-worldposta.com) and any interceptor's certificate.
class _CloudSpaceHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    if (kDebugMode) {
      client.badCertificateCallback = (X509Certificate cert, String host, int port) =>
          host == 'worldposta.com' || host.endsWith('.worldposta.com');
    }
    return client;
  }
}

class CloudSpaceApp extends StatefulWidget {
  const CloudSpaceApp({super.key});
  @override
  State<CloudSpaceApp> createState() => _CloudSpaceAppState();
}

class _CloudSpaceAppState extends State<CloudSpaceApp> with TrayListener, WindowListener {
  final _accountMgr = DriveAccountManager(tokens: SecureTokenStore(), meta: PrefsAccountMetaStore());
  DriveCache? _cache;
  DriveSyncService? _sync;
  String? _lastActiveId;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    if (_isDesktop) {
      trayManager.addListener(this);
      windowManager.addListener(this);
    }
    _init();
  }

  Future<void> _init() async {
    await _accountMgr.init();
    _accountMgr.addListener(_onAuthChanged);
    _setupCache();
    if (_isDesktop) await _initTray();
    setState(() => _initialized = true);
  }

  /// Rebind the cache + sync to the active account. Disposing the old services
  /// before building new ones guarantees one account's data (and sync journal)
  /// never lingers in another's session (isolation).
  void _setupCache() {
    final active = _accountMgr.activeAccount;
    final activeId = active?.id;
    if (active != null && (_cache == null || activeId != _lastActiveId)) {
      _cache?.dispose();
      _sync?.dispose();
      _cache = DriveCache(_accountMgr.activeApi!)..init();
      _sync = DriveSyncService(_accountMgr.activeApi!, active.id)..init();
      _lastActiveId = activeId;
    } else if (active == null) {
      _cache?.dispose();
      _sync?.dispose();
      _cache = null;
      _sync = null;
      _lastActiveId = null;
    }
  }

  void _onAuthChanged() {
    _setupCache();
    if (mounted) setState(() {});
  }

  // ── tray / window (desktop) ────────────────────────────────────────────────

  Future<String> _resolveTrayIcon() async {
    try {
      final byteData = await rootBundle.load('assets/logo.png');
      final tempDir = await getTemporaryDirectory();
      final ext = Platform.isWindows ? 'ico' : 'png';
      final iconFile = File('${tempDir.path}/cloudspace_tray.$ext');
      if (Platform.isWindows) {
        await iconFile.writeAsBytes(_pngToIco(byteData.buffer.asUint8List()));
      } else {
        await iconFile.writeAsBytes(byteData.buffer.asUint8List());
      }
      return iconFile.path;
    } catch (_) {
      return 'assets/logo.png';
    }
  }

  List<int> _pngToIco(List<int> png) {
    final size = png.length;
    final ico = <int>[0, 0, 1, 0, 1, 0, 0, 0, 0, 0, 1, 0, 32, 0];
    ico.addAll([size & 0xFF, (size >> 8) & 0xFF, (size >> 16) & 0xFF, (size >> 24) & 0xFF]);
    ico.addAll([22, 0, 0, 0]);
    ico.addAll(png);
    return ico;
  }

  Future<void> _initTray() async {
    try {
      await trayManager.setIcon(await _resolveTrayIcon(), isTemplate: false);
      await trayManager.setToolTip('Posta Drive');
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(label: 'Show Posta Drive', onClick: (_) async { await windowManager.show(); await windowManager.focus(); }),
        MenuItem.separator(),
        MenuItem(label: 'Quit', onClick: (_) async {
          await trayManager.destroy();
          await windowManager.setPreventClose(false);
          await windowManager.close();
        }),
      ]));
    } catch (_) {}
  }

  @override
  void onTrayIconMouseDown() async { await windowManager.show(); await windowManager.focus(); }
  @override
  void onTrayIconRightMouseDown() async { await trayManager.popUpContextMenu(); }
  @override
  void onWindowClose() async { await windowManager.hide(); }

  @override
  void dispose() {
    if (_isDesktop) {
      trayManager.removeListener(this);
      windowManager.removeListener(this);
    }
    _accountMgr.removeListener(_onAuthChanged);
    _cache?.dispose();
    _sync?.dispose();
    _accountMgr.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return const MaterialApp(home: Scaffold(body: Center(child: CircularProgressIndicator())));
    }
    final loggedIn = _accountMgr.isLoggedIn;
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<DriveAccountManager>.value(value: _accountMgr),
        if (_cache != null) ChangeNotifierProvider<DriveCache>.value(value: _cache!),
        if (_sync != null) ChangeNotifierProvider<DriveSyncService>.value(value: _sync!),
      ],
      child: MaterialApp(
        title: 'Posta Drive',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.lightTheme,
        // Key on the active account so the whole tree rebuilds on switch and no
        // widget keeps a stale account's state.
        home: loggedIn ? DriveHomeShell(key: ValueKey(_lastActiveId)) : const DriveLoginScreen(),
      ),
    );
  }
}
