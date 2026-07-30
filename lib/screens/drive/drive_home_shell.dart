// drive_home_shell.dart — main app shell for the new Drive.
// Sidebar (desktop) / drawer + bottom nav (mobile), top bar, and content
// routing. Account switching/add/logout live in the profile menu.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/theme.dart';
import '../../services/drive/drive_account_manager.dart';
import '../../services/drive/drive_cache.dart';
import '../../services/drive/drive_sync_service.dart';
import '../../widgets/drive_sidebar.dart';
import '../../widgets/top_bar.dart';
import '../auth/drive_login_screen.dart';
import 'drive_activity_screen.dart';
import 'drive_dashboard.dart';
import 'drive_files_screen.dart';
import 'drive_search_screen.dart';
import 'drive_settings_screen.dart';
import 'drive_sync_monitor.dart';

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
    final isWide = MediaQuery.of(context).size.width > 768;

    final sidebar = DriveSidebar(
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

    return Scaffold(
      drawer: isWide ? null : Drawer(child: sidebar),
      body: Row(children: [
        if (isWide) sidebar,
        Expanded(
          child: Column(children: [
            TopBar(
              displayName: mgr.activeAccount?.displayName,
              searchController: _searchController,
              onSettingsTap: () => setState(() => _route = 'settings'),
              onProfileTap: () => _profileMenu(context, mgr),
              onRefreshTap: () => _filesRefresh?.call() ?? cache.refresh(),
              onSearch: _onSearchChanged,
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
            Expanded(child: _content()),
          ]),
        ),
      ]),
      bottomNavigationBar: isWide
          ? null
          : BottomNavigationBar(
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
