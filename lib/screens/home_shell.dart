import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../config/theme.dart';
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

      for (final file in result.files) {
        final fileName = file.name;
        final filePath = file.path;

        Uint8List bytes;
        if (file.bytes != null) {
          bytes = file.bytes!;
        } else if (filePath != null) {
          bytes = await File(filePath).readAsBytes();
        } else {
          continue;
        }

        await webdav.uploadFile('/$fileName', bytes);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Uploaded ${result.files.length} file${result.files.length > 1 ? 's' : ''}'),
            backgroundColor: AppColors.green700,
          ),
        );
        // Refresh files view if we're on it
        setState(() => _currentRoute = 'files');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload failed: $e'), backgroundColor: AppColors.filePdf),
        );
      }
    }
  }

  Future<void> _createFolder() async {
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final controller = TextEditingController();
        return AlertDialog(
          title: const Text('New Folder'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Folder name'),
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Create')),
          ],
        );
      },
    );
    if (name == null || name.isEmpty) return;
    try {
      final auth = context.read<AuthService>();
      final webdav = WebDavService(auth);
      await webdav.createDirectory('/$name');
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
      // Create an empty file on the server at root
      await webdav.uploadFile('/$fileName', Uint8List(0));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('File "$fileName" created'), backgroundColor: AppColors.green700),
        );
        // Get file info from server to get the fileId
        setState(() => _currentRoute = 'files');
        final files = await webdav.listFiles('/');
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
    final result = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose a local folder to sync with CloudSpace',
    );
    if (result == null) return;

    if (!mounted) return;
    final sync = context.read<SyncService>();
    await sync.setSyncFolder(result, remotePath: '/');
    sync.startSync();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Sync started: ${result.split('/').last} ↔ server'),
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
        return FilesScreen(key: ValueKey('files_$_searchQuery'), mode: FileViewMode.files, searchQuery: _searchQuery);
      case 'shared':
        return FilesScreen(key: const ValueKey('shared'), mode: FileViewMode.shared);
      case 'recent':
        return FilesScreen(key: const ValueKey('recent'), mode: FileViewMode.recent);
      case 'starred':
        return FilesScreen(key: const ValueKey('starred'), mode: FileViewMode.starred);
      case 'trash':
        return FilesScreen(key: const ValueKey('trash'), mode: FileViewMode.trash);
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
                    displayName: auth.displayName,
                    onProfileTap: () => _showProfileMenu(context),
                    onSettingsTap: () => setState(() => _currentRoute = 'settings'),
                    onSearch: (query) {
                      setState(() {
                        _searchQuery = query;
                        if (query.isNotEmpty) {
                          _currentRoute = 'files';
                        }
                      });
                    },
                  ),
                // Sync status banner
                Consumer<SyncService>(
                  builder: (context, sync, _) {
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
    SyncService? sync;
    try {
      sync = context.read<SyncService>();
    } catch (_) {}

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(auth.displayName ?? 'User'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Server: ${auth.serverUrl}', style: const TextStyle(color: AppColors.body)),
            Text('User: ${auth.username}', style: const TextStyle(color: AppColors.body)),
            if (sync != null) ...[
              const SizedBox(height: 16),
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
