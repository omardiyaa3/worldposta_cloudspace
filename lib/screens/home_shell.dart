import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../config/theme.dart';
import '../services/account_manager.dart';
import '../services/auth_service.dart';
import '../services/data_cache_service.dart';
import '../services/sync_service.dart';
import '../services/webdav_service.dart';
import '../models/nc_file.dart';
import '../widgets/sidebar.dart';
import 'files/file_preview_screen.dart';
import '../widgets/top_bar.dart';
import 'dashboard/dashboard_screen.dart';
import 'files/files_screen.dart';
import 'activity_screen.dart';
import 'auth/login_screen.dart';
import 'settings/settings_screen.dart';
import 'sync_monitor_screen.dart';
import 'webview_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  String _currentRoute = 'dashboard';
  String _searchQuery = '';
  String _currentFilesPath = '/';
  Future<void> Function()? _currentRefresh;
  bool _isUploading = false;
  bool _uploadCancelled = false;
  String _uploadingFileName = '';
  int _uploadedCount = 0;
  int _uploadTotalCount = 0;
  int _uploadedBytes = 0;
  int _uploadTotalBytes = 0;

  /// Check if file exists in folder, ask user to replace or cancel. Returns true if should proceed.
  Future<bool> _checkAndConfirmOverwrite(String fileName, String folderPath) async {
    try {
      final cache = context.read<DataCacheService>();
      final files = await cache.getFolder(folderPath);
      if (files.any((f) => f.name.toLowerCase() == fileName.toLowerCase())) {
        if (!mounted) return false;
        final replace = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('File already exists'),
            content: Text('"$fileName" already exists. Do you want to replace it?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(backgroundColor: AppColors.filePdf),
                child: const Text('Replace'),
              ),
            ],
          ),
        );
        return replace == true;
      }
    } catch (_) {}
    return true; // File doesn't exist, proceed
  }

  void _showNewMenu() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.upload_file, color: AppColors.green800),
              title: const Text('Upload File'),
              onTap: () {
                Navigator.pop(ctx);
                _uploadFile();
              },
            ),
            ListTile(
              leading: const Icon(Icons.create_new_folder, color: AppColors.green800),
              title: const Text('New Folder'),
              onTap: () {
                Navigator.pop(ctx);
                _createFolder();
              },
            ),
            ListTile(
              leading: const Icon(Icons.note_add, color: AppColors.green800),
              title: const Text('New File'),
              onTap: () {
                Navigator.pop(ctx);
                _createFile();
              },
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.sync, color: AppColors.green800),
              title: const Text('Setup Sync Folder'),
              subtitle: const Text('Pick a local folder to keep in sync'),
              onTap: () {
                Navigator.pop(ctx);
                _setupSyncFolder();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _uploadFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        withData: false,
        allowMultiple: true,
      );
      if (result == null || result.files.isEmpty) return;

      final auth = context.read<AuthService>();
      final webdav = WebDavService(auth);

      int totalBytes = 0;
      for (final f in result.files) totalBytes += f.size;
      setState(() {
        _isUploading = true;
        _uploadCancelled = false;
        _uploadTotalCount = result.files.length;
        _uploadedCount = 0;
        _uploadedBytes = 0;
        _uploadTotalBytes = totalBytes;
      });

      for (int i = 0; i < result.files.length; i++) {
        if (_uploadCancelled) break;
        final file = result.files[i];
        final fileName = file.name;
        final filePath = file.path;

        setState(() { _uploadingFileName = fileName; _uploadedCount = i; });

        // Prefer file path (streams from disk) over loading into memory
        dynamic fileData;
        int fileSize;
        if (filePath != null) {
          fileData = filePath;
          fileSize = file.size;
        } else if (file.bytes != null) {
          fileData = file.bytes!;
          fileSize = file.bytes!.length;
        } else {
          continue;
        }

        final basePath = _currentRoute == 'files' ? _currentFilesPath : '/';
        if (!await _checkAndConfirmOverwrite(fileName, basePath)) continue;
        final bytesBeforeThis = _uploadedBytes;
        await webdav.uploadFileWithProgress(
          '${basePath.endsWith('/') ? basePath : '$basePath/'}$fileName',
          fileData,
          onProgress: (sent, total) {
            if (mounted) setState(() => _uploadedBytes = bytesBeforeThis + sent);
          },
          isCancelled: () => _uploadCancelled,
        );
        setState(() { _uploadedCount = i + 1; _uploadedBytes = bytesBeforeThis + fileSize; });
      }

      if (mounted) {
        setState(() => _isUploading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Uploaded ${result.files.length} file${result.files.length > 1 ? 's' : ''}'),
            backgroundColor: AppColors.green700,
          ),
        );
        setState(() => _currentRoute = 'files');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isUploading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload failed: $e'), backgroundColor: AppColors.filePdf),
        );
      }
    }
  }

  Future<void> _createFolder() async {
    final basePath = _currentRoute == 'files' ? _currentFilesPath : '/';
    // Load existing items directly from server for duplicate check
    List<NcFile> existingItems = [];
    try {
      final auth = context.read<AuthService>();
      final webdav = WebDavService(auth);
      existingItems = await webdav.listFiles(basePath);
    } catch (_) {}

    if (!mounted) return;
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final controller = TextEditingController();
        String? errorText;
        return StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: const Text('New Folder'),
            content: TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(hintText: 'Folder name', errorText: errorText),
              onSubmitted: (v) {
                final val = v.trim();
                if (val.isEmpty) {
                  setDialogState(() => errorText = 'Please enter a folder name');
                } else if (existingItems.any((f) => f.name.toLowerCase() == val.toLowerCase())) {
                  setDialogState(() => errorText = '"$val" already exists');
                } else {
                  Navigator.pop(ctx, val);
                }
              },
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              ElevatedButton(onPressed: () {
                final val = controller.text.trim();
                if (val.isEmpty) {
                  setDialogState(() => errorText = 'Please enter a folder name');
                } else if (existingItems.any((f) => f.name.toLowerCase() == val.toLowerCase())) {
                  setDialogState(() => errorText = '"$val" already exists');
                } else {
                  Navigator.pop(ctx, val);
                }
              }, child: const Text('Create')),
            ],
          ),
        );
      },
    );
    if (name == null || name.isEmpty) return;
    try {
      final auth = context.read<AuthService>();
      final webdav = WebDavService(auth);
      await webdav.createDirectory('${basePath.endsWith('/') ? basePath : '$basePath/'}$name');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Created folder "$name"'), backgroundColor: AppColors.green700),
        );
        setState(() => _currentRoute = 'files');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e')),
        );
      }
    }
  }

  Future<void> _createFile() async {
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) {
        String selectedType = 'txt';
        final nameController = TextEditingController(text: 'Untitled');
        final types = {
          'txt': 'Text File (.txt)',
          'docx': 'Document (.docx)',
          'xlsx': 'Spreadsheet (.xlsx)',
          'pptx': 'Presentation (.pptx)',
        };
        return StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: const Text('New File'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // File type picker
                ...types.entries.map((e) => RadioListTile<String>(
                  title: Text(e.value),
                  value: e.key,
                  groupValue: selectedType,
                  onChanged: (v) => setDialogState(() => selectedType = v!),
                  dense: true,
                  activeColor: AppColors.green800,
                )),
                const SizedBox(height: 12),
                TextField(
                  controller: nameController,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: 'File name',
                    suffixText: '.$selectedType',
                  ),
                  onSubmitted: (_) => Navigator.pop(ctx, {'name': nameController.text, 'ext': selectedType}),
                ),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, {'name': nameController.text, 'ext': selectedType}),
                child: const Text('Create'),
              ),
            ],
          ),
        );
      },
    );
    if (result == null || result['name']!.trim().isEmpty) return;
    final fileName = '${result['name']!.trim()}.${result['ext']}';
    try {
      final auth = context.read<AuthService>();
      final webdav = WebDavService(auth);
      final basePath = _currentRoute == 'files' ? _currentFilesPath : '/';
      if (!await _checkAndConfirmOverwrite(fileName, basePath)) return;
      final remotePath = '${basePath.endsWith('/') ? basePath : '$basePath/'}$fileName';
      await webdav.uploadFile(remotePath, Uint8List(0));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('File "$fileName" created'), backgroundColor: AppColors.green700),
        );
        // Get file info from server to get the fileId
        setState(() => _currentRoute = 'files');
        final files = await webdav.listFiles(basePath);
        final newFile = files.where((f) => f.name == fileName).firstOrNull;
        if (newFile != null && mounted) {
          // Refresh cache
          try { context.read<DataCacheService>().refresh(); } catch (_) {}
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => FilePreviewScreen(file: newFile)),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e'), backgroundColor: AppColors.filePdf),
        );
      }
    }
  }

  Future<void> _setupSyncFolder() async {
    String? result;
    if (Platform.isIOS || Platform.isAndroid) {
      final dir = await getApplicationDocumentsDirectory();
      result = '${dir.path}/CloudSpace';
      await Directory(result).create(recursive: true);
    } else {
      result = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Choose a local folder to sync with CloudSpace',
      );
    }
    if (result == null) return;

    if (!mounted) return;
    final sync = context.read<SyncService>();
    await sync.setSyncFolder(result, remotePath: '/');
    sync.startSync();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(Platform.isIOS || Platform.isAndroid
              ? 'Sync started. Files available in Files app → On My iPhone → CloudSpace'
              : 'Sync started: ${result.split('/').last} ↔ server'),
          backgroundColor: AppColors.green700,
        ),
      );
    }
  }

  Widget _buildContent() {
    switch (_currentRoute) {
      case 'dashboard':
        return DashboardScreen(
          onNavigateToFiles: () => setState(() => _currentRoute = 'files'),
        );
      case 'files':
        return FilesScreen(key: ValueKey('files_${_searchQuery}'), mode: FileViewMode.files, searchQuery: _searchQuery, onPathChanged: (p) => _currentFilesPath = p, onRefreshReady: (fn) => _currentRefresh = fn);
      case 'shared':
        return FilesScreen(key: ValueKey('shared'), mode: FileViewMode.shared, onRefreshReady: (fn) => _currentRefresh = fn);
      case 'recent':
        return FilesScreen(key: ValueKey('recent'), mode: FileViewMode.recent, onRefreshReady: (fn) => _currentRefresh = fn);
      case 'starred':
        return FilesScreen(key: ValueKey('starred'), mode: FileViewMode.starred, onRefreshReady: (fn) => _currentRefresh = fn);
      case 'trash':
        return FilesScreen(key: ValueKey('trash'), mode: FileViewMode.trash, onRefreshReady: (fn) => _currentRefresh = fn);
      case 'activity':
        return const ActivityScreen();
      case 'settings':
        return const SettingsScreen();
      case 'sync_monitor':
        return const SyncMonitorScreen();
      case 'talk':
        return const NextcloudWebView(
          key: ValueKey('talk'),
          appPath: '/index.php/apps/spreed/',
          title: 'Talk',
        );
      default:
        return DashboardScreen(
          onNavigateToFiles: () => setState(() => _currentRoute = 'files'),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final accountMgr = context.watch<AccountManager>();
    final auth = context.watch<AuthService>();
    final cache = context.watch<DataCacheService>();
    final usedStorage = ((cache.quota['used'] as int?) ?? 0).toDouble();
    final totalStorage = ((cache.quota['total'] as int?) ?? 0).toDouble();
    final isWide = MediaQuery.of(context).size.width > 768;

    return Scaffold(
      // Mobile drawer
      drawer: isWide
          ? null
          : Drawer(
              child: AppSidebar(
                currentRoute: _currentRoute,
                usedStorage: usedStorage,
                totalStorage: totalStorage,
                onNewPressed: _showNewMenu,
                onNavigate: (route) {
                  setState(() => _currentRoute = route);
                  Navigator.pop(context);
                },
              ),
            ),
      body: Row(
        children: [
          // Desktop sidebar
          if (isWide)
            AppSidebar(
              currentRoute: _currentRoute,
              usedStorage: usedStorage,
              totalStorage: totalStorage,
              onNewPressed: _showNewMenu,
              onNavigate: (route) => setState(() => _currentRoute = route),
            ),

          // Main content
          Expanded(
            child: Column(
              children: [
                // Hide top bar for WebView routes — they have their own UI
                if (!_isWebViewRoute)
                  TopBar(
                    displayName: accountMgr.displayName ?? auth.displayName,
                    onProfileTap: () => _showProfileMenu(context),
                    onSettingsTap: () => setState(() => _currentRoute = 'settings'),
                    onRefreshTap: () {
                      _currentRefresh?.call();
                    },
                    onSearch: (query) {
                      setState(() {
                        _searchQuery = query;
                        if (query.isNotEmpty) {
                          _currentRoute = 'files';
                        }
                      });
                    },
                  ),
                // Quota warning banner
                if (cache.quotaWarningLevel == 'critical')
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    color: AppColors.filePdf.withValues(alpha: 0.15),
                    child: Row(
                      children: [
                        const Icon(Icons.warning_amber_rounded, size: 16, color: AppColors.filePdf),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Storage almost full (${totalStorage > 0 ? ((usedStorage / totalStorage) * 100).toInt() : 0}% used)! Free up space.',
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.filePdf),
                          ),
                        ),
                      ],
                    ),
                  ),
                // Sync status banner
                Builder(
                  builder: (context) {
                    SyncService? sync;
                    try { sync = context.watch<SyncService>(); } catch (_) { return const SizedBox.shrink(); }
                    if (!sync.isSyncing && !sync.isEnabled) return const SizedBox.shrink();
                    return GestureDetector(
                      onTap: () => setState(() => _currentRoute = 'sync_monitor'),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        color: sync.isSyncing ? AppColors.greenActiveBg : AppColors.grey96,
                        child: Row(
                          children: [
                            if (sync.isSyncing)
                              const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: AppColors.green700,
                                ),
                              )
                            else
                              const Icon(Icons.cloud_done, size: 14, color: AppColors.green800),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                sync.isSyncing
                                    ? 'Syncing${sync.currentFile.isNotEmpty ? ": ${sync.currentFile}" : "..."}'
                                    : sync.status,
                                style: const TextStyle(fontSize: 12, color: AppColors.heading),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (sync.isSyncing && sync.totalFilesToSync > 0) ...[
                              const SizedBox(width: 8),
                              SizedBox(
                                width: 80,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(3),
                                  child: LinearProgressIndicator(
                                    value: sync.filesProcessed / sync.totalFilesToSync,
                                    backgroundColor: AppColors.grey91,
                                    color: AppColors.green700,
                                    minHeight: 4,
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(width: 8),
                            const Icon(Icons.chevron_right, size: 16, color: AppColors.azure65),
                          ],
                        ),
                      ),
                    );
                  },
                ),
                // Upload progress banner
                if (_isUploading)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    color: AppColors.greenActiveBg,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.green700)),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                'Uploading $_uploadingFileName ($_uploadedCount/$_uploadTotalCount)',
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppColors.heading),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Text(
                              '${(_uploadedBytes / (1024 * 1024)).toStringAsFixed(1)} / ${(_uploadTotalBytes / (1024 * 1024)).toStringAsFixed(1)} MB',
                              style: const TextStyle(fontSize: 11, color: AppColors.muted),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              icon: const Icon(Icons.close, size: 18, color: AppColors.filePdf),
                              tooltip: 'Cancel upload',
                              onPressed: () => setState(() { _uploadCancelled = true; _isUploading = false; }),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: _uploadTotalBytes > 0 ? _uploadedBytes / _uploadTotalBytes : 0,
                            backgroundColor: AppColors.grey91,
                            color: AppColors.green700,
                            minHeight: 4,
                          ),
                        ),
                      ],
                    ),
                  ),
                Expanded(child: _buildContent()),
              ],
            ),
          ),

          // Right app rail (desktop only)
          if (isWide)
            Container(
              width: 48,
              color: AppColors.white,
              child: Column(
                children: [
                  const Spacer(),
                  _AppRailIcon(
                    icon: Icons.sync,
                    isActive: _currentRoute == 'sync_monitor',
                    onTap: () => setState(() => _currentRoute = 'sync_monitor'),
                  ),
                  const SizedBox(height: 8),
                  _AppRailIcon(icon: Icons.add, onTap: _showNewMenu),
                  const SizedBox(height: 16),
                ],
              ),
            ),
        ],
      ),

      // Mobile bottom nav
      bottomNavigationBar: isWide
          ? null
          : BottomNavigationBar(
              currentIndex: _mobileNavIndex,
              onTap: (i) {
                setState(() {
                  _currentRoute = ['dashboard', 'files', 'shared', 'starred', 'trash'][i];
                });
              },
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

      // Mobile FAB for upload
      floatingActionButton: (!isWide && (_currentRoute == 'files' || _currentRoute == 'dashboard'))
          ? FloatingActionButton(
              onPressed: _showNewMenu,
              backgroundColor: AppColors.green800,
              child: const Icon(Icons.add, color: AppColors.white),
            )
          : null,
    );
  }

  bool get _isWebViewRoute => _currentRoute == 'talk';

  int get _mobileNavIndex {
    switch (_currentRoute) {
      case 'dashboard': return 0;
      case 'files': return 1;
      case 'shared': return 2;
      case 'starred': return 3;
      case 'trash': return 4;
      default: return 0;
    }
  }

  void _showProfileMenu(BuildContext context) {
    final auth = context.read<AuthService>();
    final accountMgr = context.read<AccountManager>();
    SyncService? sync;
    try {
      sync = context.read<SyncService>();
    } catch (_) {}

    final activeAccount = accountMgr.activeAccount;
    final otherAccounts = accountMgr.accounts
        .where((a) => a.id != activeAccount?.id)
        .toList();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(accountMgr.displayName ?? auth.displayName ?? 'User'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Server: ${accountMgr.serverUrl ?? auth.serverUrl}', style: const TextStyle(color: AppColors.body)),
            Text('User: ${accountMgr.username ?? auth.username}', style: const TextStyle(color: AppColors.body)),

            // Other accounts section
            if (otherAccounts.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
              const Text('Switch Account', style: TextStyle(fontWeight: FontWeight.w600, color: AppColors.heading)),
              const SizedBox(height: 4),
              ...otherAccounts.map((account) => ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(
                  radius: 16,
                  backgroundColor: AppColors.green700,
                  child: Text(
                    account.displayName.isNotEmpty ? account.displayName[0].toUpperCase() : 'U',
                    style: const TextStyle(color: AppColors.white, fontSize: 13),
                  ),
                ),
                title: Text(account.displayName, style: const TextStyle(fontSize: 13)),
                subtitle: Text(account.serverUrl, style: const TextStyle(fontSize: 11, color: AppColors.muted)),
                trailing: IconButton(
                  icon: const Icon(Icons.logout, size: 16, color: AppColors.filePdf),
                  tooltip: 'Remove account',
                  onPressed: () {
                    Navigator.pop(ctx);
                    accountMgr.logout(account.id);
                  },
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  // Pop all pushed routes (file preview, settings, etc.) back to home
                  Navigator.of(context).popUntil((route) => route.isFirst);
                  accountMgr.switchAccount(account.id);
                },
              )),
            ],

            // Add Account button
            const SizedBox(height: 8),
            const Divider(),
            const SizedBox(height: 4),
            TextButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                // Navigate to login screen for adding a new account
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const LoginScreen()),
                );
              },
              icon: const Icon(Icons.person_add, size: 16, color: AppColors.green800),
              label: const Text('Add Account', style: TextStyle(color: AppColors.green800)),
            ),

            if (sync != null) ...[
              const Divider(),
              const SizedBox(height: 8),
              const Text('Sync', style: TextStyle(fontWeight: FontWeight.w600, color: AppColors.heading)),
              const SizedBox(height: 4),
              Text(
                sync.syncFolderPath != null
                    ? 'Folder: ${sync.syncFolderPath!.split('/').last}'
                    : 'No sync folder configured',
                style: const TextStyle(color: AppColors.body, fontSize: 13),
              ),
              Text(
                'Status: ${sync.status}',
                style: const TextStyle(color: AppColors.body, fontSize: 13),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  if (sync.isEnabled)
                    TextButton.icon(
                      onPressed: () { sync!.stopSync(); Navigator.pop(ctx); },
                      icon: const Icon(Icons.stop, size: 16),
                      label: const Text('Stop Sync'),
                    )
                  else if (sync.syncFolderPath != null)
                    TextButton.icon(
                      onPressed: () { sync!.startSync(); Navigator.pop(ctx); },
                      icon: const Icon(Icons.play_arrow, size: 16),
                      label: const Text('Start Sync'),
                    ),
                  if (sync.isEnabled)
                    TextButton.icon(
                      onPressed: () { sync!.syncNow(); Navigator.pop(ctx); },
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('Sync Now'),
                    ),
                  TextButton.icon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _showSyncLog(context, sync!);
                    },
                    icon: const Icon(Icons.article_outlined, size: 16),
                    label: const Text('View Log'),
                  ),
                ],
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              // Log out of both systems
              if (activeAccount != null) {
                accountMgr.logoutCurrent();
              }
              auth.logout();
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.filePdf),
            child: const Text('Log Out'),
          ),
        ],
      ),
    );
  }

  void _showSyncLog(BuildContext context, SyncService sync) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sync Log'),
        content: SizedBox(
          width: 600,
          height: 400,
          child: sync.log.isEmpty
              ? const Center(child: Text('No log entries yet. Run a sync first.'))
              : ListView.builder(
                  itemCount: sync.log.length,
                  itemBuilder: (_, i) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      sync.log[i],
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: sync.log[i].contains('ERROR') || sync.log[i].contains('FAIL')
                            ? AppColors.filePdf
                            : sync.log[i].contains('DOWNLOAD') || sync.log[i].contains('UPLOAD')
                                ? AppColors.green800
                                : AppColors.body,
                      ),
                    ),
                  ),
                ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }
}

class _AppRailIcon extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool isActive;

  const _AppRailIcon({required this.icon, required this.onTap, this.isActive = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: IconButton(
        onPressed: onTap,
        style: isActive
            ? IconButton.styleFrom(backgroundColor: AppColors.greenActiveBg)
            : null,
        icon: Icon(icon, size: 20, color: isActive ? AppColors.green800 : AppColors.azure47),
      ),
    );
  }
}
