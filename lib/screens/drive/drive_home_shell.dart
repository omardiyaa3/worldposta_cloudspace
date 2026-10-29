// drive_home_shell.dart — main app shell for the new Drive.
// Sidebar (desktop) / drawer + bottom nav (mobile), top bar, and content
// routing. Account switching/add/logout live in the profile menu.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/theme.dart';
import '../../services/drive/drive_account_manager.dart';
import '../../services/drive/drive_cache.dart';
import '../../services/drive/drive_api.dart';
import '../../services/drive/drive_client.dart';
import '../../services/drive/drive_sync_service.dart';
import '../../widgets/drive_sidebar.dart';
import '../../widgets/notification_bell.dart';
import '../../widgets/top_bar.dart';
import '../auth/drive_login_screen.dart';
import 'drive_activity_screen.dart';
import 'drive_dashboard.dart';
import 'drive_files_screen.dart';
import 'drive_google_screen.dart';
import 'drive_open_file.dart';
import 'drive_search_screen.dart';
import 'drive_settings_screen.dart';
import 'drive_sync_monitor.dart';
import 'drive_tags_screen.dart';
import '../../config/layout.dart';
import '../../services/reserved_region.dart';

class DriveHomeShell extends StatefulWidget {
  const DriveHomeShell({super.key});

  @override
  State<DriveHomeShell> createState() => _DriveHomeShellState();
}

class _DriveHomeShellState extends State<DriveHomeShell> {
  String _route = 'dashboard';
  Future<void> Function()? _filesRefresh;
  VoidCallback? _filesNewMenu; // opens the Files "New" menu
  bool _pendingNew = false; // "New" was pressed while not on Files yet
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  // "Google Drive" shows only when the server has Google import set up; checked
  // once per account.
  bool _googleConfigured = false;
  String? _googleCheckedFor;

  Future<void> _checkGoogle(DriveAccountManager mgr) async {
    final id = mgr.activeAccount?.id;
    final api = mgr.activeApi;
    if (id == null || api == null || id == _googleCheckedFor) return;
    _googleCheckedFor = id;
    var configured = false;
    try {
      configured = (await api.googleConnection()).configured;
    } catch (_) {/* older server / offline → hide the section */}
    if (mounted && _googleCheckedFor == id) setState(() => _googleConfigured = configured);
  }

  /// A notification about a file: open it (folders open in My Drive).
  Future<void> _openFromNotification(String fileId) async {
    final api = context.read<DriveAccountManager>().activeApi;
    if (api == null) return;
    try {
      final f = await api.fileDetail(fileId);
      if (!mounted) return;
      if (f.isDirectory) {
        setState(() => _route = 'files');
      } else {
        await openDriveFile(context, f);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e)), backgroundColor: AppColors.filePdf));
      }
    }
  }

  // Live search: the top-bar field is the single persistent input; typing swaps
  // the content area to live results (debounced) instead of pushing a screen.
  final _searchController = TextEditingController();
  String _searchQuery = '';
  Timer? _searchDebounce;

  void _onSearchChanged(String q) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      final trimmed = q.trim();
      if (trimmed != _searchQuery) setState(() => _searchQuery = trimmed);
    });
  }

  void _clearSearch() {
    _searchDebounce?.cancel();
    _searchController.clear();
    if (_searchQuery.isNotEmpty) setState(() => _searchQuery = '');
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Widget _content() {
    if (_searchQuery.isNotEmpty) {
      return DriveSearchResults(query: _searchQuery);
    }
    switch (_route) {
      case 'files':
        return DriveFilesScreen(
          key: const ValueKey('files'),
          mode: DriveViewMode.files,
          onRefreshReady: (fn) => _filesRefresh = fn,
          onNewMenuReady: (fn) {
            _filesNewMenu = fn;
            if (_pendingNew) {
              _pendingNew = false;
              WidgetsBinding.instance.addPostFrameCallback((_) => fn());
            }
          },
        );
      case 'recent':
        return DriveFilesScreen(key: const ValueKey('recent'), mode: DriveViewMode.recent, onRefreshReady: (fn) => _filesRefresh = fn);
      case 'starred':
        return DriveFilesScreen(key: const ValueKey('starred'), mode: DriveViewMode.starred, onRefreshReady: (fn) => _filesRefresh = fn);
      case 'shared':
        return DriveFilesScreen(key: const ValueKey('shared'), mode: DriveViewMode.shared, onRefreshReady: (fn) => _filesRefresh = fn);
      case 'trash':
        return DriveFilesScreen(key: const ValueKey('trash'), mode: DriveViewMode.trash, onRefreshReady: (fn) => _filesRefresh = fn);
      case 'pinned':
        return DriveFilesScreen(key: const ValueKey('pinned'), mode: DriveViewMode.pinned, onRefreshReady: (fn) => _filesRefresh = fn);
      case 'shortcuts':
        return DriveFilesScreen(key: const ValueKey('shortcuts'), mode: DriveViewMode.shortcuts, onRefreshReady: (fn) => _filesRefresh = fn);
      case 'tags':
        return const DriveTagsScreen(key: ValueKey('tags'));
      case 'google':
        return const DriveGoogleScreen(key: ValueKey('google'));
      case 'activity':
        return const DriveActivityScreen();
      case 'settings':
        return const DriveSettingsScreen();
      default:
        return DriveDashboard(onNavigateToFiles: () => setState(() => _route = 'files'));
    }
  }

  void _onNew() {
    // Open the Files "New" menu (Upload / New Folder / New File). If we're not on
    // the Files tab yet, switch to it and open the menu once it registers.
    if (_route == 'files' && _filesNewMenu != null) {
      _filesNewMenu!();
    } else {
      _pendingNew = true;
      setState(() => _route = 'files');
    }
  }

  Widget _syncBanner(BuildContext context) {
    DriveSyncService? sync;
    try {
      sync = context.watch<DriveSyncService>();
    } catch (_) {
      return const SizedBox.shrink();
    }
    final s = sync;
    if (!s.isEnabled && !s.isSyncing) return const SizedBox.shrink();
    return GestureDetector(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DriveSyncMonitor())),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        color: s.isSyncing ? AppColors.greenActiveBg : AppColors.grey96,
        child: Row(children: [
          if (s.isSyncing)
            const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.green700))
          else
            const Icon(Icons.cloud_done, size: 14, color: AppColors.green800),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              s.isSyncing ? 'Syncing${s.currentFile.isNotEmpty ? ': ${s.currentFile}' : '…'}' : s.status,
              style: const TextStyle(fontSize: 12, color: AppColors.heading),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const Icon(Icons.chevron_right, size: 16, color: AppColors.azure65),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mgr = context.watch<DriveAccountManager>();
    final cache = context.watch<DriveCache>();
    final isWide = isWideLayout(context);
    _checkGoogle(mgr);
    final api = mgr.activeApi;

    final sidebar = DriveSidebar(
      showGoogleDrive: _googleConfigured,
      currentRoute: _route,
      usedBytes: cache.usedBytes,
      totalBytes: cache.totalBytes,
      onNewPressed: _onNew,
      onNavigate: (r) {
        _clearSearch();
        setState(() => _route = r);
        if (!isWide) Navigator.maybePop(context);
      },
    );

    return ValueListenableBuilder<ReservedTopRegion?>(
      valueListenable: ReservedRegions.instance,
      builder: (context, region, _) => _scaffold(context, mgr, cache, api, isWide, sidebar, region),
    );
  }

  /// Page names for the large title shown beside the iPhone Duo's bubble.
  static const _titles = {
    'dashboard': 'Home', 'files': 'My Drive', 'shared': 'Shared', 'recent': 'Recent', 'starred': 'Starred',
    'trash': 'Trash', 'pinned': 'Pinned', 'shortcuts': 'Shortcuts', 'tags': 'Tags', 'google': 'Google Drive',
    'activity': 'Activity', 'settings': 'Settings',
  };

  Widget _scaffold(BuildContext context, DriveAccountManager mgr, DriveCache cache, DriveApi? api, bool isWide,
      Widget sidebar, ReservedTopRegion? region) {
    final mq = MediaQuery.of(context);
    // iPhone Duo: the host moved the safe area's top below the status bubble.
    // The band beside the bubble holds the top bar and a large page title;
    // the sidebar / drawer (left of the bubble) use the full height.
    final band = region != null && region.rect.bottom > region.systemTop ? region : null;
    final belowBubble = band == null ? mq : mq.copyWith(
      padding: mq.padding.copyWith(top: band.systemTop),
      viewPadding: mq.viewPadding.copyWith(top: band.systemTop),
    );
    final trailing = band == null ? 0.0 : (mq.size.width - band.rect.left).clamp(0.0, mq.size.width / 2);
    final titleHeight = band == null ? 0.0 : band.rect.bottom - band.systemTop - 56;
    final topBar = TopBar(
              displayName: mgr.activeAccount?.displayName,
              searchController: _searchController,
              onSettingsTap: () => setState(() => _route = 'settings'),
              onProfileTap: () => _profileMenu(context, mgr),
              onRefreshTap: () => _filesRefresh?.call() ?? cache.refresh(),
              onSearch: _onSearchChanged,
              onMenuTap: isWide ? null : () => _scaffoldKey.currentState?.openDrawer(),
              notifications: api == null
                  ? null
                  : DriveNotificationBell(
                      key: ValueKey('bell-${mgr.activeAccount?.id}'),
                      api: api,
                      onOpenFile: _openFromNotification,
                    ),
              trailingInset: trailing,
              showBorder: band == null,
            );
    return Scaffold(
      key: _scaffoldKey,
      drawer: isWide ? null : MediaQuery(data: belowBubble, child: Drawer(child: sidebar)),
      body: Row(children: [
        if (isWide) MediaQuery(data: belowBubble, child: sidebar),
        Expanded(
          child: Column(children: [
            if (band == null)
              topBar
            else
              Container(
                decoration: const BoxDecoration(
                  color: AppColors.white,
                  border: Border(bottom: BorderSide(color: AppColors.grey91, width: 1)),
                ),
                child: MediaQuery(
                  data: belowBubble,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    topBar,
                    if (titleHeight > 0)
                      SizedBox(
                        height: titleHeight,
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(isWide ? 24 : 16, 0, trailing + 12, 4),
                          child: Align(
                            // Centred in the band's remaining height: reads as one
                            // header with the bar above it, no empty strip.
                            alignment: Alignment.centerLeft,
                            child: Text(
                              _searchQuery.isNotEmpty ? 'Search' : (_titles[_route] ?? 'Posta Drive'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: 'PublicSans',
                                fontSize: titleHeight >= 80 ? 32 : 24,
                                fontWeight: FontWeight.w700,
                                color: AppColors.heading,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ]),
                ),
              ),
            if (cache.quotaWarningLevel == 'critical')
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                color: AppColors.filePdf.withValues(alpha: 0.15),
                child: const Row(children: [
                  Icon(Icons.warning_amber_rounded, size: 16, color: AppColors.filePdf),
                  SizedBox(width: 8),
                  Expanded(child: Text('Storage almost full! Free up space.', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.filePdf))),
                ]),
              ),
            _syncBanner(context),
            Expanded(child: MediaQuery.removePadding(context: context, removeTop: true, child: _content())),
          ]),
        ),
      ]),
      bottomNavigationBar: isWide
          ? null
          : Container(
              // White with a hairline on top, like the top bar (the default
              // Material tint made it pinkish).
              decoration: const BoxDecoration(
                color: AppColors.white,
                border: Border(top: BorderSide(color: AppColors.grey91, width: 1)),
              ),
              child: BottomNavigationBar(
              backgroundColor: AppColors.white,
              elevation: 0,
              currentIndex: const ['dashboard', 'files', 'shared', 'starred', 'trash'].indexOf(_route).clamp(0, 4),
              onTap: (i) { _clearSearch(); setState(() => _route = ['dashboard', 'files', 'shared', 'starred', 'trash'][i]); },
              type: BottomNavigationBarType.fixed,
              selectedItemColor: AppColors.green800,
              unselectedItemColor: AppColors.muted,
              selectedFontSize: 11,
              unselectedFontSize: 11,
              items: const [
                BottomNavigationBarItem(icon: Icon(Icons.dashboard_outlined), label: 'Home'),
                BottomNavigationBarItem(icon: Icon(Icons.folder_outlined), label: 'Files'),
                BottomNavigationBarItem(icon: Icon(Icons.share_outlined), label: 'Shared'),
                BottomNavigationBarItem(icon: Icon(Icons.star_outline), label: 'Starred'),
                BottomNavigationBarItem(icon: Icon(Icons.delete_outline), label: 'Trash'),
              ],
            ),
            ),
    );
  }

  void _profileMenu(BuildContext context, DriveAccountManager mgr) {
    final active = mgr.activeAccount;
    final others = mgr.accounts.where((a) => a.id != active?.id).toList();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(active?.displayName ?? 'Account'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Email: ${active?.email ?? '—'}', style: const TextStyle(color: AppColors.body)),
          Text('Server: ${active?.serverUrl ?? '—'}', style: const TextStyle(color: AppColors.body)),
          if (others.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Divider(),
            const Text('Switch Account', style: TextStyle(fontWeight: FontWeight.w600, color: AppColors.heading)),
            ...others.map((a) => ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(radius: 16, backgroundColor: AppColors.green700, child: Text(a.displayName.isNotEmpty ? a.displayName[0].toUpperCase() : 'U', style: const TextStyle(color: AppColors.white, fontSize: 13))),
                  title: Text(a.displayName, style: const TextStyle(fontSize: 13)),
                  subtitle: Text(a.email, style: const TextStyle(fontSize: 11, color: AppColors.muted)),
                  trailing: IconButton(
                    icon: const Icon(Icons.logout, size: 16, color: AppColors.filePdf),
                    tooltip: 'Remove',
                    onPressed: () { Navigator.pop(ctx); mgr.removeAccount(a.id); },
                  ),
                  onTap: () { Navigator.pop(ctx); setState(() => _route = 'dashboard'); mgr.switchAccount(a.id); },
                )),
          ],
          const SizedBox(height: 8),
          const Divider(),
          TextButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              // Capture the root NavigatorState BEFORE pushing: adding an account
              // rebuilds `home` with a new key, which deactivates this widget's
              // context. Popping via a captured NavigatorState (it lives above
              // `home`, so it survives the rebuild) avoids a null-check crash.
              final nav = Navigator.of(context, rootNavigator: true);
              // On success pop ALL pushed auth routes back to the home shell. SSO
              // pushes two (login → webview); a single maybePop would leave the
              // login screen visible, stranding the user on it after adding an
              // account. popUntil(isFirst) returns to the (rebuilt) home reliably.
              nav.push(MaterialPageRoute(builder: (_) => DriveLoginScreen(onSignedIn: () => nav.popUntil((r) => r.isFirst))));
            },
            icon: const Icon(Icons.person_add, size: 16, color: AppColors.green800),
            label: const Text('Add Account', style: TextStyle(color: AppColors.green800)),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          ElevatedButton(
            onPressed: () { Navigator.pop(ctx); mgr.logoutCurrent(); },
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.filePdf),
            child: const Text('Log Out'),
          ),
        ],
      ),
    );
  }
}
