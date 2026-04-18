import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../config/theme.dart';
import '../../models/nc_file.dart';
import '../../services/auth_service.dart';
import '../../services/data_cache_service.dart';
import '../../services/sync_service.dart';
import '../../services/webdav_service.dart';
import '../../widgets/file_type_badge.dart';
import 'file_preview_screen.dart';

enum FileViewMode { files, shared, recent, starred, trash }
enum SortColumn { name, owner, date, size }
enum SortDir { asc, desc }

class FilesScreen extends StatefulWidget {
  final FileViewMode mode;
  final String searchQuery;
  final ValueChanged<String>? onPathChanged;
  final ValueChanged<Future<void> Function()>? onRefreshReady;

  const FilesScreen({super.key, this.mode = FileViewMode.files, this.searchQuery = '', this.onPathChanged, this.onRefreshReady});

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  String _currentPath = '/';
  List<NcFile> _files = [];
  List<NcFile> _filteredFiles = [];
  bool _isLoading = true;  // Full-screen spinner (first load only)
  bool _isRefreshing = false;  // Subtle indicator while updating in background
  bool _isGridView = true;
  bool _isUploading = false;
  String _uploadingFileName = '';
  int _uploadedCount = 0;
  int _uploadTotalCount = 0;
  int _uploadedBytes = 0;
  int _uploadTotalBytes = 0;
  bool _isDownloading = false;
  String _downloadingFileName = '';
  int _downloadedBytes = 0;
  int _downloadTotalBytes = 0;
  String? _error;
  String _searchQuery = '';

  /// Clean up raw exceptions into user-friendly messages.
  String _friendlyError(Object e) {
    final s = e.toString();
    if (s.contains('SocketException') || s.contains('ClientException') || s.contains('HandshakeException')) {
      return 'Connection lost. Check your internet and try again.';
    }
    if (s.contains('TimeoutException') || s.contains('timed out')) {
      return 'Request timed out. Please try again.';
    }
    if (s.contains('403')) return 'Access denied.';
    if (s.contains('404')) return 'Not found on server.';
    if (s.contains('500') || s.contains('502') || s.contains('503')) return 'Server error. Try again later.';
    // Truncate long messages
    if (s.length > 80) return '${s.substring(0, 80)}...';
    return s;
  }
  SortColumn _sortColumn = SortColumn.name;
  SortDir _sortDir = SortDir.asc;
  bool _showSharedByMe = false;
  List<NcFile> _sharedByMeFiles = [];
  int _newSharePermission = 15; // Default: can edit
  final _sharePasswordController = TextEditingController();
  DateTime? _shareExpiration;
  bool _isDragging = false;
  List<NcFile> _sharedWithMeFiles = [];

  @override
  void initState() {
    super.initState();
    _loadFiles();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<DataCacheService>().addListener(_onCacheChanged);
      widget.onRefreshReady?.call(refresh);
    });
  }

  bool _cacheListenerPaused = false;

  bool _loadInProgress = false;

  void _onCacheChanged() {
    if (!mounted || _cacheListenerPaused || _loadInProgress) return;
    _loadFiles();
  }

  /// Called by parent (home_shell) via GlobalKey to trigger visible refresh
  Future<void> refresh() async {
    if (!mounted) return;
    setState(() => _isRefreshing = true);
    try {
      final cache = context.read<DataCacheService>();
      switch (widget.mode) {
        case FileViewMode.files:
          cache.clearFolderCache(_currentPath);
          await cache.refreshFolder(_currentPath);
        case FileViewMode.shared:
          await cache.refreshShared();
        case FileViewMode.recent:
          await cache.refreshRecent();
        case FileViewMode.starred:
          await cache.refreshStarred();
        case FileViewMode.trash:
          await cache.refreshTrash();
      }
    } catch (_) {}
    _cacheListenerPaused = true;
    await _loadFiles();
    _cacheListenerPaused = false;
    // Background full refresh
    try { context.read<DataCacheService>().refresh(); } catch (_) {}
  }

  @override
  void dispose() {
    try {
      context.read<DataCacheService>().removeListener(_onCacheChanged);
    } catch (_) {}
    super.dispose();
  }

  Future<void> _loadFiles() async {
    if (_loadInProgress) return;
    _loadInProgress = true;

    // First load: full spinner. Subsequent loads: subtle refresh indicator.
    if (_files.isEmpty && !_isRefreshing) {
      setState(() { _isLoading = true; _error = null; });
    } else {
      setState(() { _isRefreshing = true; });
    }

    try {
      final cache = context.read<DataCacheService>();

      List<NcFile> files;
      if (widget.searchQuery.isNotEmpty && !_browsingAfterSearch) {
        final auth = context.read<AuthService>();
        final webdav = WebDavService(auth);
        files = await webdav.search(widget.searchQuery);
      } else {
        switch (widget.mode) {
          case FileViewMode.files:
            files = await cache.getFolder(_currentPath);
          case FileViewMode.shared:
            // If not loaded yet, fetch immediately
            if (cache.sharedWithMe.isEmpty && cache.sharedByMe.isEmpty && !cache.isFullyLoaded) {
              await cache.refreshShared();
            }
            _sharedWithMeFiles = cache.sharedWithMe;
            _sharedByMeFiles = cache.sharedByMe;
            files = _showSharedByMe ? cache.sharedByMe : cache.sharedWithMe;
          case FileViewMode.recent:
            files = cache.recentFiles;
          case FileViewMode.starred:
            if (cache.starredFiles.isEmpty && !cache.isFullyLoaded) {
              await cache.refreshStarred();
            }
            files = cache.starredFiles;
          case FileViewMode.trash:
            if (cache.trashFiles.isEmpty && !cache.isFullyLoaded) {
              await cache.refreshTrash();
            }
            files = cache.trashFiles;
        }
      }

      if (mounted) {
        setState(() {
          _files = files;
          _applyFilterAndSort();
          _isLoading = false;
          _isRefreshing = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          if (_files.isEmpty) _error = _friendlyError(e);
          _isLoading = false;
          _isRefreshing = false;
        });
      }
    } finally {
      _loadInProgress = false;
    }
  }

  void _applyFilterAndSort() {
    var list = List<NcFile>.from(_files);

    // Search filter
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      list = list.where((f) => f.name.toLowerCase().contains(q)).toList();
    }

    // Sort — directories always first
    list.sort((a, b) {
      // Directories first
      if (a.isDirectory && !b.isDirectory) return -1;
      if (!a.isDirectory && b.isDirectory) return 1;

      int cmp;
      switch (_sortColumn) {
        case SortColumn.name:
          cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case SortColumn.owner:
          cmp = (a.ownerDisplayName ?? '').compareTo(b.ownerDisplayName ?? '');
        case SortColumn.date:
          cmp = (a.lastModified ?? DateTime(2000)).compareTo(b.lastModified ?? DateTime(2000));
        case SortColumn.size:
          cmp = a.size.compareTo(b.size);
      }
      return _sortDir == SortDir.asc ? cmp : -cmp;
    });

    _filteredFiles = list;
  }

  void _onSort(SortColumn col) {
    setState(() {
      if (_sortColumn == col) {
        _sortDir = _sortDir == SortDir.asc ? SortDir.desc : SortDir.asc;
      } else {
        _sortColumn = col;
        _sortDir = SortDir.asc;
      }
      _applyFilterAndSort();
    });
  }

  void _onSearch(String query) {
    setState(() {
      _searchQuery = query;
      _applyFilterAndSort();
    });
  }

  bool _browsingAfterSearch = false;

  void _navigateToFolder(NcFile folder) {
    if (widget.mode != FileViewMode.files) return;
    setState(() {
      _currentPath = folder.path;
      _files = [];
      _filteredFiles = [];
      // If we're in search results, switch to normal folder browsing
      if (widget.searchQuery.isNotEmpty) _browsingAfterSearch = true;
    });
    widget.onPathChanged?.call(folder.path);
    _loadFiles();
  }

  void _navigateToBreadcrumb(int index) {
    final parts = _currentPath.split('/').where((p) => p.isNotEmpty).toList();
    final newPath = '/${parts.sublist(0, index + 1).join('/')}';
    setState(() {
      _currentPath = newPath;
      _files = [];
      _filteredFiles = [];
    });
    widget.onPathChanged?.call(newPath);
    _loadFiles();
  }

  Future<void> _uploadFiles(List<PlatformFile> files) async {
    try {
      setState(() {
        _isUploading = true;
        _uploadedCount = 0;
        _uploadTotalCount = files.length;
        _uploadedBytes = 0;
        _uploadTotalBytes = 0;
        _uploadingFileName = files.first.name;
      });

      // Calculate total bytes
      int totalBytes = 0;
      for (final f in files) {
        totalBytes += f.size;
      }
      setState(() => _uploadTotalBytes = totalBytes);

      final auth = context.read<AuthService>();
      final webdav = WebDavService(auth);

      for (var i = 0; i < files.length; i++) {
        final file = files[i];
        final fileName = file.name;
        final filePath = file.path;

        if (mounted) {
          setState(() {
            _uploadingFileName = fileName;
            _uploadedCount = i;
          });
        }

        Uint8List bytes;
        if (file.bytes != null) {
          bytes = file.bytes!;
        } else if (filePath != null) {
          bytes = await File(filePath).readAsBytes();
        } else {
          continue;
        }

        final remotePath =
            '$_currentPath${_currentPath.endsWith('/') ? '' : '/'}$fileName';
        await webdav.uploadFile(remotePath, bytes);

        if (mounted) {
          setState(() {
            _uploadedBytes += bytes.length;
            _uploadedCount = i + 1;
          });
        }
      }

      await _loadFiles();

      if (mounted) {
        setState(() => _isUploading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Uploaded ${files.length} file${files.length > 1 ? 's' : ''}'),
            backgroundColor: AppColors.green700,
          ),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _isUploading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload failed: ${_friendlyError(e)}'), backgroundColor: AppColors.filePdf),
        );
      }
    }
  }

  Future<void> _uploadFile() async {
    final result = await FilePicker.platform.pickFiles(
      withData: false,
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return;
    await _uploadFiles(result.files);
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
    if (_files.any((f) => f.name == name)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('"$name" already exists'), backgroundColor: AppColors.filePdf),
        );
      }
      return;
    }
    try {
      final auth = context.read<AuthService>();
      final webdav = WebDavService(auth);
      await webdav.createDirectory('$_currentPath${_currentPath.endsWith('/') ? '' : '/'}$name');
      // Clear just this folder's cache, then reload once
      if (mounted) {
        context.read<DataCacheService>().clearFolderCache(_currentPath);
      }
      await _loadFiles();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Folder "$name" created'), backgroundColor: AppColors.green700),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_friendlyError(e))));
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
      final remotePath = '$_currentPath${_currentPath.endsWith('/') ? '' : '/'}$fileName';
      await webdav.uploadFile(remotePath, Uint8List(0));
      // Clear just this folder's cache, then reload once
      if (mounted) {
        context.read<DataCacheService>().clearFolderCache(_currentPath);
      }
      await _loadFiles();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('File "$fileName" created'), backgroundColor: AppColors.green700),
        );
        // Open it in preview screen (text files in edit mode, office files via web editor)
        final newFile = NcFile(
          path: remotePath,
          name: fileName,
          isDirectory: false,
          size: 0,
          lastModified: DateTime.now(),
          contentType: 'application/octet-stream',
        );
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => FilePreviewScreen(file: newFile)),
        );
      }
    } catch (e) {
      if (mounted) {
        final msg = e.toString().contains('FILE_EXISTS')
            ? '"$fileName" already exists'
            : _friendlyError(e);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: AppColors.filePdf));
      }
    }
  }

  Future<void> _deleteFile(NcFile file) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${file.name}?'),
        content: Text(file.isDirectory
            ? 'This will delete the folder and all its contents.'
            : 'This file will be moved to trash.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.filePdf),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final auth = context.read<AuthService>();
      final webdav = WebDavService(auth);
      await webdav.delete(file.path);
      if (mounted) {
        final cache = context.read<DataCacheService>();
        cache.clearFolderCache(_currentPath);
        cache.rootFiles.removeWhere((f) => f.path == file.path);
        setState(() {
          _files.removeWhere((f) => f.path == file.path);
          _applyFilterAndSort();
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${file.name} deleted'), backgroundColor: AppColors.green700),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Delete failed: ${_friendlyError(e)}')));
      }
    }
  }

  Future<void> _permanentlyDeleteFromTrash(NcFile file) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Permanently delete ${file.name}?'),
        content: const Text('This action cannot be undone. The file will be gone forever.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.filePdf),
            child: const Text('Permanently Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final auth = context.read<AuthService>();
      final webdav = WebDavService(auth);
      await webdav.deleteFromTrash(file.path);
      if (mounted) {
        context.read<DataCacheService>().trashFiles.removeWhere((f) => f.path == file.path);
        setState(() {
          _files.removeWhere((f) => f.path == file.path);
          _applyFilterAndSort();
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${file.name} permanently deleted'), backgroundColor: AppColors.green700),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Delete failed: ${_friendlyError(e)}')));
      }
    }
  }

  Future<void> _restoreFromTrash(NcFile file) async {
    try {
      final auth = context.read<AuthService>();
      final webdav = WebDavService(auth);
      // ownerDisplayName stores the original location for trash items
      final originalLocation = file.ownerDisplayName ?? file.name;
      debugPrint('Restoring trash item: path=${file.path}, originalLocation=$originalLocation');
      await webdav.restoreFromTrash(file.path, originalLocation, isDirectory: file.isDirectory);
      if (mounted) {
        // Remove from local list AND cache immediately
        final cache = context.read<DataCacheService>();
        cache.trashFiles.removeWhere((f) => f.path == file.path);
        setState(() {
          _files.removeWhere((f) => f.path == file.path);
          _applyFilterAndSort();
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${file.name} restored'), backgroundColor: AppColors.green700),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Restore failed: ${_friendlyError(e)}')));
      }
    }
  }

  Future<void> _renameFile(NcFile file) async {
    final controller = TextEditingController(text: file.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'New name'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    if (newName == null || newName.isEmpty || newName == file.name) return;
    try {
      final auth = context.read<AuthService>();
      final webdav = WebDavService(auth);
      final newPath = '${file.parentPath}/$newName';
      await webdav.move(file.path, newPath);
      if (mounted) {
        context.read<DataCacheService>().clearFolderCache(_currentPath);
        await _loadFiles();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Renamed to $newName'), backgroundColor: AppColors.green700),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Rename failed: ${_friendlyError(e)}')));
      }
    }
  }

  Future<void> _moveFile(NcFile file) async {
    final auth = context.read<AuthService>();
    final webdav = WebDavService(auth);
    final destination = await showDialog<String>(
      context: context,
      builder: (ctx) => _MoveToDialog(webdav: webdav, fileName: file.name, filePath: file.path),
    );
    if (destination == null) return;
    try {
      final destPath = '$destination${destination.endsWith('/') ? '' : '/'}${file.name}';
      await webdav.move(file.path, destPath);
      if (mounted) {
        setState(() {
          _files.removeWhere((f) => f.path == file.path);
          _applyFilterAndSort();
        });
        context.read<DataCacheService>().clearFolderCache(_currentPath);
        context.read<DataCacheService>().clearFolderCache(destination);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Moved "${file.name}" to $destination'), backgroundColor: AppColors.green700),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Move failed: ${_friendlyError(e)}')));
      }
    }
  }

  Future<void> _toggleFavorite(NcFile file) async {
    try {
      final auth = context.read<AuthService>();
      final webdav = WebDavService(auth);
      final newFav = !file.isFavorite;
      await webdav.toggleFavorite(file.path, newFav);
      if (mounted) {
        final cache = context.read<DataCacheService>();
        // Update cache instantly
        if (newFav) {
          cache.starredFiles.add(file.copyWith(isFavorite: true));
        } else {
          cache.starredFiles.removeWhere((f) => f.path == file.path);
        }
        // Update local list instantly
        final idx = _files.indexWhere((f) => f.path == file.path);
        if (idx >= 0) {
          setState(() {
            _files[idx] = _files[idx].copyWith(isFavorite: newFav);
            _applyFilterAndSort();
          });
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(file.isFavorite ? 'Removed from favorites' : 'Added to favorites'),
            backgroundColor: AppColors.green700,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_friendlyError(e))));
      }
    }
  }

  Future<void> _setReminder(NcFile file) async {
    final now = DateTime.now();
    final picked = await showDialog<DateTime>(
      context: context,
      builder: (ctx) {
        DateTime selected = now.add(const Duration(hours: 1));
        return StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: Text('Remind me about ${file.name}'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Quick options
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _ReminderChip(label: 'In 1 hour', onTap: () => Navigator.pop(ctx, now.add(const Duration(hours: 1)))),
                    _ReminderChip(label: 'Tomorrow 9am', onTap: () {
                      final tomorrow = DateTime(now.year, now.month, now.day + 1, 9);
                      Navigator.pop(ctx, tomorrow);
                    }),
                    _ReminderChip(label: 'Next week', onTap: () => Navigator.pop(ctx, now.add(const Duration(days: 7)))),
                  ],
                ),
                const SizedBox(height: 16),
                const Divider(),
                const SizedBox(height: 8),
                // Custom date/time
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () async {
                          final date = await showDatePicker(
                            context: ctx,
                            initialDate: selected,
                            firstDate: now,
                            lastDate: now.add(const Duration(days: 365)),
                          );
                          if (date != null) {
                            setDialogState(() {
                              selected = DateTime(date.year, date.month, date.day, selected.hour, selected.minute);
                            });
                          }
                        },
                        child: Text('${selected.day}/${selected.month}/${selected.year}'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () async {
                          final time = await showTimePicker(
                            context: ctx,
                            initialTime: TimeOfDay.fromDateTime(selected),
                          );
                          if (time != null) {
                            setDialogState(() {
                              selected = DateTime(selected.year, selected.month, selected.day, time.hour, time.minute);
                            });
                          }
                        },
                        child: Text('${selected.hour.toString().padLeft(2, '0')}:${selected.minute.toString().padLeft(2, '0')}'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              ElevatedButton(onPressed: () => Navigator.pop(ctx, selected), child: const Text('Set Reminder')),
            ],
          ),
        );
      },
    );

    if (picked == null) return;

    // Set reminder via Nextcloud OCS API
    try {
      final auth = context.read<AuthService>();
      final timestamp = picked.millisecondsSinceEpoch ~/ 1000;
      final url = Uri.parse(
        '${auth.serverUrl}/ocs/v1.php/apps/files_reminders/api/v1/reminders/${file.fileId}?format=json',
      );
      debugPrint('Reminder URL: $url fileId=${file.fileId}');
      final response = await WebDavService.sharedHttpClient.put(
        url,
        headers: {
          'Authorization': auth.basicAuth,
          'OCS-APIRequest': 'true',
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: '{"dueDate":"${picked.toUtc().toIso8601String()}"}',
      );
      debugPrint('Reminder response: ${response.statusCode} ${response.body}');

      if (mounted) {
        if (response.statusCode == 200 || response.statusCode == 201) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Reminder set for ${DateFormat('MMM d, y h:mm a').format(picked)}'),
              backgroundColor: AppColors.green700,
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Reminder failed: ${response.statusCode}')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Reminder failed: ${_friendlyError(e)}')));
      }
    }
  }

  Future<void> _shareFile(NcFile file) async {
    _newSharePermission = 1; // Default to read-only for public links
    final auth = context.read<AuthService>();
    final sharesUrl = Uri.parse(
      '${auth.serverUrl}/ocs/v1.php/apps/files_sharing/api/v1/shares?path=${Uri.encodeComponent(file.path)}&format=json',
    );
    final headers = {
      'Authorization': auth.basicAuth,
      'OCS-APIRequest': 'true',
    };

    // Fetch existing shares for this file
    List<Map<String, dynamic>> existingShares = [];
    try {
      final resp = await WebDavService.sharedHttpClient.get(sharesUrl, headers: headers);
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        final shares = data['ocs']?['data'] as List? ?? [];
        existingShares = shares.cast<Map<String, dynamic>>();
      }
    } catch (_) {}

    if (!mounted) return;

    final shareWithController = TextEditingController();
    int? _selectedShareType; // Store shareType from autocomplete selection

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        String shareError = '';
        String shareSuccess = '';
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return Padding(
              padding: EdgeInsets.fromLTRB(24, 20, 24, MediaQuery.of(ctx).viewInsets.bottom + 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Success banner inside the sheet
                  if (shareSuccess.isNotEmpty)
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppColors.green700.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.check_circle, size: 16, color: AppColors.green700),
                          const SizedBox(width: 8),
                          Expanded(child: Text(shareSuccess, style: const TextStyle(fontSize: 12, color: AppColors.green800))),
                          GestureDetector(
                            onTap: () => setSheetState(() => shareSuccess = ''),
                            child: const Icon(Icons.close, size: 14, color: AppColors.green700),
                          ),
                        ],
                      ),
                    ),
                  // Error banner inside the sheet
                  if (shareError.isNotEmpty && shareError != '...')
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppColors.filePdf.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.error_outline, size: 16, color: AppColors.filePdf),
                          const SizedBox(width: 8),
                          Expanded(child: Text(shareError, style: const TextStyle(fontSize: 12, color: AppColors.filePdf))),
                          GestureDetector(
                            onTap: () => setSheetState(() => shareError = ''),
                            child: const Icon(Icons.close, size: 14, color: AppColors.filePdf),
                          ),
                        ],
                      ),
                    ),
                  Row(
                    children: [
                      const Icon(Icons.share, color: AppColors.green800, size: 22),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Share "${file.name}"',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.heading),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // --- Share with people section ---
                  const Text('Share with user or email', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.heading)),
                  const SizedBox(height: 8),
                  _ShareAutocompleteField(
                    controller: shareWithController,
                    serverUrl: auth.serverUrl!,
                    basicAuth: auth.basicAuth,
                    onShareTypeSelected: (type) => _selectedShareType = type,
                  ),
                  const SizedBox(height: 8),
                  // Permission picker for new share
                  Row(
                    children: [
                      const Text('Permission: ', style: TextStyle(fontSize: 13, color: AppColors.body)),
                      const SizedBox(width: 8),
                      DropdownButton<int>(
                        value: _newSharePermission,
                        underline: const SizedBox.shrink(),
                        style: const TextStyle(fontSize: 13, color: AppColors.heading),
                        items: const [
                          DropdownMenuItem(value: 1, child: Text('View only')),
                          DropdownMenuItem(value: 15, child: Text('Can edit')),
                          DropdownMenuItem(value: 31, child: Text('Can edit + reshare')),
                        ],
                        onChanged: (v) {
                          if (v != null) setSheetState(() => _newSharePermission = v);
                        },
                      ),
                      TextButton(
                        onPressed: () async {
                          final custom = await _showCustomPermissionsDialog(ctx, _newSharePermission);
                          if (custom != null) setSheetState(() => _newSharePermission = custom);
                        },
                        child: const Text('Custom', style: TextStyle(fontSize: 12, color: AppColors.green700)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // Password protection
                  TextField(
                    controller: _sharePasswordController,
                    obscureText: true,
                    onChanged: (_) => setSheetState(() {}),
                    decoration: InputDecoration(
                      hintText: 'Password (optional)',
                      prefixIcon: const Icon(Icons.lock_outline, size: 18, color: AppColors.muted),
                      filled: true,
                      fillColor: AppColors.grey96,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                    style: const TextStyle(fontSize: 14),
                  ),
                  // Password strength indicator
                  if (_sharePasswordController.text.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4, left: 4),
                      child: Builder(builder: (_) {
                        final pwd = _sharePasswordController.text;
                        String label;
                        Color color;
                        if (pwd.length >= 8 && RegExp(r'(?=.*[a-z])(?=.*[A-Z])(?=.*\d)').hasMatch(pwd)) {
                          label = 'Strong';
                          color = AppColors.green700;
                        } else if (pwd.length >= 4) {
                          label = 'Fair';
                          color = Colors.orange;
                        } else {
                          label = 'Weak';
                          color = Colors.red;
                        }
                        return Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color));
                      }),
                    ),
                  const SizedBox(height: 8),
                  // Expiration date
                  InkWell(
                    onTap: () async {
                      final date = await showDatePicker(
                        context: ctx,
                        initialDate: _shareExpiration ?? DateTime.now().add(const Duration(days: 7)),
                        firstDate: DateTime.now(),
                        lastDate: DateTime.now().add(const Duration(days: 365)),
                      );
                      if (date != null) setSheetState(() => _shareExpiration = date);
                    },
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      decoration: BoxDecoration(
                        color: AppColors.grey96,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.calendar_today, size: 18, color: AppColors.muted),
                          const SizedBox(width: 8),
                          Text(
                            _shareExpiration != null
                                ? 'Expires: ${DateFormat('MMM d, y').format(_shareExpiration!)}'
                                : 'Expiration date (optional)',
                            style: TextStyle(fontSize: 14, color: _shareExpiration != null ? AppColors.heading : AppColors.muted),
                          ),
                          if (_shareExpiration != null) ...[
                            const Spacer(),
                            GestureDetector(
                              onTap: () => setSheetState(() => _shareExpiration = null),
                              child: const Icon(Icons.close, size: 16, color: AppColors.muted),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: AppColors.green700),
                      onPressed: shareError == '...' ? null : () async {
                        final shareWith = shareWithController.text.trim();
                        if (shareWith.isEmpty) return;
                        // Check if already shared with this person
                        if (existingShares.any((s) => s['share_with'] == shareWith || s['share_with_displayname'] == shareWith)) {
                          setSheetState(() => shareError = 'Already shared with $shareWith');
                          return;
                        }
                        setSheetState(() { shareError = '...'; shareSuccess = ''; }); // '...' = loading
                        // Use shareType from autocomplete if available
                        // If user typed manually: try as user (0) first, if 404 retry as email (4)
                        int resolvedType = _selectedShareType ?? -1;
                        if (resolvedType == 10) resolvedType = 0; // Talk room → try as user
                        if (resolvedType == -1) {
                          // No autocomplete selection — guess from format
                          resolvedType = 0; // Try user first
                        }
                        final shareType = '$resolvedType';
                        try {
                          final postUrl = Uri.parse(
                            '${auth.serverUrl}/ocs/v1.php/apps/files_sharing/api/v1/shares?format=json',
                          );
                          final resp = await WebDavService.sharedHttpClient.post(postUrl, headers: {
                            ...headers,
                            'Content-Type': 'application/x-www-form-urlencoded',
                          }, body: {
                            'path': file.path,
                            'shareType': shareType,
                            'shareWith': shareWith,
                            'permissions': '$_newSharePermission',
                            if (_sharePasswordController.text.isNotEmpty)
                              'password': _sharePasswordController.text,
                            if (_shareExpiration != null)
                              'expireDate': '${_shareExpiration!.year}-${_shareExpiration!.month.toString().padLeft(2, '0')}-${_shareExpiration!.day.toString().padLeft(2, '0')}',
                          });
                            debugPrint('Share create response: ${resp.statusCode} ${resp.body}');
                            if (!ctx.mounted) return;

                            // If user share failed with 404, retry as email share
                            var finalResp = resp;
                            if (resp.statusCode == 200) {
                              final checkData = jsonDecode(resp.body);
                              final checkMeta = checkData['ocs']?['meta'];
                              if (checkMeta?['statuscode'] == 404 && shareType == '0' && shareWith.contains('@')) {
                                debugPrint('User share 404, retrying as email (type 4)...');
                                finalResp = await WebDavService.sharedHttpClient.post(postUrl, headers: {
                                  ...headers,
                                  'Content-Type': 'application/x-www-form-urlencoded',
                                }, body: {
                                  'path': file.path,
                                  'shareType': '4',
                                  'shareWith': shareWith,
                                  'permissions': '$_newSharePermission',
                                });
                                debugPrint('Email share response: ${finalResp.statusCode} ${finalResp.body}');
                              }
                            }
                            if (!ctx.mounted) return;

                            if (finalResp.statusCode == 200) {
                              final data = jsonDecode(finalResp.body);
                              final meta = data['ocs']?['meta'];
                              if (meta != null && meta['statuscode'] != null && meta['statuscode'] != 200 && meta['statuscode'] != 100) {
                                setSheetState(() => shareError = meta['message'] ?? 'Share failed');
                                return;
                              }
                              // data can be a Map or a List (OCS v1 quirk)
                              final rawData = data['ocs']?['data'];
                              Map<String, dynamic>? newShare;
                              if (rawData is Map<String, dynamic>) {
                                newShare = rawData;
                              } else if (rawData is List && rawData.isNotEmpty) {
                                newShare = rawData.first as Map<String, dynamic>?;
                              }

                              // Check if server applied different permissions, try PUT to fix
                              if (newShare != null) {
                                final appliedPerms = newShare['permissions'] ?? 0;
                                if (appliedPerms != _newSharePermission) {
                                  debugPrint('Server applied perms=$appliedPerms, requested=$_newSharePermission, trying PUT...');
                                  final shareId = newShare['id'];
                                  final putUrl = Uri.parse(
                                    '${auth.serverUrl}/ocs/v1.php/apps/files_sharing/api/v1/shares/$shareId?format=json',
                                  );
                                  final putResp = await WebDavService.sharedHttpClient.put(putUrl, headers: {
                                    ...headers,
                                  }, body: 'permissions=$_newSharePermission',
                                  encoding: Encoding.getByName('utf-8'));
                                  debugPrint('Share PUT response: ${putResp.statusCode} ${putResp.body}');
                                  if (putResp.statusCode == 200) {
                                    final putData = jsonDecode(putResp.body);
                                    final putRaw = putData['ocs']?['data'];
                                    if (putRaw is Map<String, dynamic>) {
                                      newShare = putRaw;
                                    } else if (putRaw is List && putRaw.isNotEmpty) {
                                      newShare = putRaw.first as Map<String, dynamic>? ?? newShare;
                                    }
                                  }
                                }
                              }

                              if (newShare != null) {
                                try {
                                  setSheetState(() => existingShares = [...existingShares, newShare!]);
                                } catch (_) {}
                              }
                              shareWithController.clear();
                              _sharePasswordController.clear();
                              setSheetState(() {
                                _shareExpiration = null;
                                shareSuccess = 'Shared with $shareWith';
                                shareError = '';
                              });
                            } else {
                              String errorMsg = 'Share failed: ${finalResp.statusCode}';
                              try {
                                final data = jsonDecode(finalResp.body);
                                errorMsg = data['ocs']?['meta']?['message'] ?? errorMsg;
                              } catch (_) {}
                              setSheetState(() => shareError = errorMsg);
                            }
                          } catch (e) {
                            setSheetState(() => shareError = 'Share failed: $e');
                          }
                        },
                        child: shareError == '...'
                            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.white))
                            : const Text('Share'),
                      ),
                    ),
                  const SizedBox(height: 20),

                  // --- Create link section ---
                  CheckboxListTile(
                    value: _newSharePermission > 1,
                    onChanged: (v) => setSheetState(() => _newSharePermission = (v == true) ? 15 : 1),
                    title: const Text('Allow editing', style: TextStyle(fontSize: 13)),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    activeColor: AppColors.green800,
                  ),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.link, size: 18),
                      label: const Text('Create Public Link'),
                      style: OutlinedButton.styleFrom(foregroundColor: AppColors.green700),
                      onPressed: () async {
                        try {
                          final postUrl = Uri.parse(
                            '${auth.serverUrl}/ocs/v1.php/apps/files_sharing/api/v1/shares?format=json',
                          );
                          final resp = await WebDavService.sharedHttpClient.post(postUrl, headers: {
                            ...headers,
                            'Content-Type': 'application/x-www-form-urlencoded',
                          }, body: {
                            'path': file.path,
                            'shareType': '3',
                            'permissions': '$_newSharePermission',
                            if (_sharePasswordController.text.isNotEmpty)
                              'password': _sharePasswordController.text,
                            if (_shareExpiration != null)
                              'expireDate': '${_shareExpiration!.year}-${_shareExpiration!.month.toString().padLeft(2, '0')}-${_shareExpiration!.day.toString().padLeft(2, '0')}',
                          });
                          debugPrint('Link share response: ${resp.statusCode} ${resp.body}');
                          if (!ctx.mounted) return;
                          if (resp.statusCode == 200) {
                            final body = resp.body;
                            // Try JSON first, fall back to XML
                            String shareUrl = '';
                            try {
                              final data = jsonDecode(body);
                              shareUrl = data['ocs']?['data']?['url'] ?? '';
                              final linkRaw = data['ocs']?['data'];
                              Map<String, dynamic>? newShare;
                              if (linkRaw is Map<String, dynamic>) newShare = linkRaw;
                              else if (linkRaw is List && linkRaw.isNotEmpty) newShare = linkRaw.first as Map<String, dynamic>?;
                              if (newShare != null) {
                                try { setSheetState(() => existingShares = [...existingShares, newShare!]); } catch (_) {}
                              }
                            } catch (_) {
                              final urlMatch = RegExp(r'<url>(.*?)</url>').firstMatch(body);
                              shareUrl = urlMatch?.group(1) ?? '';
                            }
                            if (shareUrl.isNotEmpty) {
                              Clipboard.setData(ClipboardData(text: shareUrl));
                              setSheetState(() {
                                shareSuccess = 'Public link created and copied to clipboard';
                                shareError = '';
                              });
                            } else {
                              setSheetState(() {
                                shareSuccess = 'Public link created';
                                shareError = '';
                              });
                            }
                          } else {
                            String errorMsg = 'Link creation failed: ${resp.statusCode}';
                            try {
                              final errData = jsonDecode(resp.body);
                              errorMsg = errData['ocs']?['meta']?['message'] ?? errorMsg;
                            } catch (_) {}
                            setSheetState(() => shareError = errorMsg);
                          }
                        } catch (e) {
                          setSheetState(() => shareError = 'Link creation failed: $e');
                        }
                      },
                    ),
                  ),
                  const SizedBox(height: 20),

                  // --- Existing shares ---
                  if (existingShares.isNotEmpty) ...[
                    const Text('Current shares', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.heading)),
                    const SizedBox(height: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 300),
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: existingShares.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final s = existingShares[i];
                          final type = s['share_type'] ?? -1;
                          final shareWith = s['share_with_displayname'] ?? s['share_with'] ?? '';
                          final url = s['url'] ?? '';
                          final shareId = s['id'];
                          final perms = s['permissions'] ?? 1;
                          final isPublicLink = type == 3;
                          final itemType = s['item_type'] ?? 'file';
                          final isFolder = itemType == 'folder';
                          IconData icon;
                          String label;
                          // Display permissions ignoring auto-added share bit
                          final corePerms = perms & 15; // mask out share bit (16)
                          String permLabel;
                          if (corePerms == 1 || perms == 1 || perms == 17) {
                            permLabel = 'View only';
                          } else if (corePerms == 15 || corePerms == 7 || perms == 31) {
                            permLabel = 'Can edit';
                          } else {
                            final parts = <String>[];
                            if (perms & 2 != 0) parts.add('update');
                            if (perms & 4 != 0) parts.add('create');
                            if (perms & 8 != 0) parts.add('delete');
                            permLabel = parts.isEmpty ? 'View only' : 'Can ${parts.join(', ')}';
                          }
                          if (type == 3) {
                            icon = Icons.link;
                            label = 'Public link';
                          } else if (type == 4) {
                            icon = Icons.email_outlined;
                            label = shareWith;
                          } else if (type == 0) {
                            icon = Icons.person_outline;
                            label = shareWith;
                          } else if (type == 1) {
                            icon = Icons.group_outlined;
                            label = shareWith;
                          } else {
                            icon = Icons.share;
                            label = shareWith.isNotEmpty ? shareWith : 'Share #$shareId';
                          }
                          return ListTile(
                            dense: true,
                            leading: Icon(icon, size: 20, color: AppColors.green800),
                            title: Text(label, style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis),
                            subtitle: Text(permLabel, style: const TextStyle(fontSize: 11, color: AppColors.muted)),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (type == 3 && url.isNotEmpty)
                                  IconButton(
                                    icon: const Icon(Icons.copy, size: 16),
                                    tooltip: 'Copy link',
                                    onPressed: () {
                                      Clipboard.setData(ClipboardData(text: url));
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(content: Text('Link copied'), backgroundColor: AppColors.green700),
                                      );
                                    },
                                  ),
                                // Permission menu — delete and recreate to change permissions
                                if (!isPublicLink)
                                  PopupMenuButton<String>(
                                    icon: const Icon(Icons.settings, size: 16, color: AppColors.muted),
                                    tooltip: 'Change permissions',
                                    onSelected: (value) async {
                                      if (value == 'remove') {
                                        // Remove person from share
                                        try {
                                          final delUrl = Uri.parse(
                                            '${auth.serverUrl}/ocs/v1.php/apps/files_sharing/api/v1/shares/$shareId?format=json',
                                          );
                                          await WebDavService.sharedHttpClient.delete(delUrl, headers: headers);
                                          setSheetState(() {
                                            existingShares = List.from(existingShares)..removeAt(i);
                                          });
                                          setSheetState(() { shareSuccess = 'Share removed'; shareError = ''; });
                                        } catch (e) {
                                          setSheetState(() { shareError = 'Failed to remove: $e'; shareSuccess = ''; });
                                        }
                                        return;
                                      }

                                      int? newPerms;
                                      if (value == '1') {
                                        newPerms = 1;
                                      } else if (value == '15') {
                                        newPerms = 15;
                                      } else if (value == 'custom') {
                                        newPerms = await _showCustomPermissionsDialog(context, perms);
                                      }
                                      if (newPerms == null || newPerms == (perms & 15)) return;

                                      // Delete old share, create new one with updated perms
                                      try {
                                        // Delete
                                        final delUrl = Uri.parse(
                                          '${auth.serverUrl}/ocs/v1.php/apps/files_sharing/api/v1/shares/$shareId?format=json',
                                        );
                                        await WebDavService.sharedHttpClient.delete(delUrl, headers: headers);

                                        // Recreate with new permissions
                                        final postUrl = Uri.parse(
                                          '${auth.serverUrl}/ocs/v1.php/apps/files_sharing/api/v1/shares?format=json',
                                        );
                                        final resp = await WebDavService.sharedHttpClient.post(postUrl, headers: {
                                          ...headers,
                                          'Content-Type': 'application/x-www-form-urlencoded',
                                        }, body: {
                                          'path': file.path,
                                          'shareType': '$type',
                                          'shareWith': shareWith,
                                          'permissions': '$newPerms',
                                        });
                                        debugPrint('Recreate share response: ${resp.statusCode} ${resp.body}');

                                        if (resp.statusCode == 200 && context.mounted) {
                                          final data = jsonDecode(resp.body);
                                          final recreateRaw = data['ocs']?['data'];
                                          Map<String, dynamic>? newShare;
                                          if (recreateRaw is Map<String, dynamic>) newShare = recreateRaw;
                                          else if (recreateRaw is List && recreateRaw.isNotEmpty) newShare = recreateRaw.first as Map<String, dynamic>?;
                                          if (newShare != null) {
                                            setSheetState(() {
                                              existingShares = List.from(existingShares)..[i] = newShare!;
                                              shareSuccess = 'Permissions updated';
                                              shareError = '';
                                            });
                                          } else {
                                            setSheetState(() { shareSuccess = 'Permissions updated'; shareError = ''; });
                                          }
                                        }
                                      } catch (e) {
                                        setSheetState(() { shareError = 'Failed: $e'; shareSuccess = ''; });
                                      }
                                    },
                                    itemBuilder: (_) => [
                                      PopupMenuItem(
                                        value: '1',
                                        child: Row(children: [
                                          Icon(Icons.visibility, size: 16, color: corePerms == 1 ? AppColors.green800 : AppColors.body),
                                          const SizedBox(width: 8),
                                          Text('View only', style: TextStyle(color: corePerms == 1 ? AppColors.green800 : null)),
                                        ]),
                                      ),
                                      PopupMenuItem(
                                        value: '15',
                                        child: Row(children: [
                                          Icon(Icons.edit, size: 16, color: corePerms >= 7 ? AppColors.green800 : AppColors.body),
                                          const SizedBox(width: 8),
                                          Text('Can edit', style: TextStyle(color: corePerms >= 7 ? AppColors.green800 : null)),
                                        ]),
                                      ),
                                      const PopupMenuItem(
                                        value: 'custom',
                                        child: Row(children: [
                                          Icon(Icons.tune, size: 16, color: AppColors.body),
                                          SizedBox(width: 8),
                                          Text('Custom permissions'),
                                        ]),
                                      ),
                                      const PopupMenuDivider(),
                                      const PopupMenuItem(
                                        value: 'remove',
                                        child: Row(children: [
                                          Icon(Icons.person_remove, size: 16, color: AppColors.filePdf),
                                          SizedBox(width: 8),
                                          Text('Remove from share', style: TextStyle(color: AppColors.filePdf)),
                                        ]),
                                      ),
                                    ],
                                  ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<int?> _showCustomPermissionsDialog(BuildContext context, int currentPerms) async {
    bool read = currentPerms & 1 != 0;
    bool update = currentPerms & 2 != 0;
    bool create = currentPerms & 4 != 0;
    bool delete = currentPerms & 8 != 0;
    bool share = currentPerms & 16 != 0;

    return showDialog<int>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: const Text('Custom Permissions'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CheckboxListTile(
                  title: const Text('Read', style: TextStyle(fontSize: 14)),
                  subtitle: const Text('View and download', style: TextStyle(fontSize: 12)),
                  value: read,
                  activeColor: AppColors.green800,
                  onChanged: (v) => setDialogState(() => read = v ?? true),
                ),
                CheckboxListTile(
                  title: const Text('Update', style: TextStyle(fontSize: 14)),
                  subtitle: const Text('Edit existing files', style: TextStyle(fontSize: 12)),
                  value: update,
                  activeColor: AppColors.green800,
                  onChanged: (v) => setDialogState(() => update = v ?? false),
                ),
                CheckboxListTile(
                  title: const Text('Create', style: TextStyle(fontSize: 14)),
                  subtitle: const Text('Upload new files', style: TextStyle(fontSize: 12)),
                  value: create,
                  activeColor: AppColors.green800,
                  onChanged: (v) => setDialogState(() => create = v ?? false),
                ),
                CheckboxListTile(
                  title: const Text('Delete', style: TextStyle(fontSize: 14)),
                  subtitle: const Text('Remove files', style: TextStyle(fontSize: 12)),
                  value: delete,
                  activeColor: AppColors.green800,
                  onChanged: (v) => setDialogState(() => delete = v ?? false),
                ),
                CheckboxListTile(
                  title: const Text('Share', style: TextStyle(fontSize: 14)),
                  subtitle: const Text('Can reshare with others', style: TextStyle(fontSize: 12)),
                  value: share,
                  activeColor: AppColors.green800,
                  onChanged: (v) => setDialogState(() => share = v ?? false),
                ),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              ElevatedButton(
                onPressed: () {
                  int perms = 0;
                  if (read) perms |= 1;
                  if (update) perms |= 2;
                  if (create) perms |= 4;
                  if (delete) perms |= 8;
                  if (share) perms |= 16;
                  if (perms == 0) perms = 1; // At least read
                  Navigator.pop(ctx, perms);
                },
                child: const Text('Apply'),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showFileActivity(NcFile file) {
    final auth = context.read<AuthService>();
    final webdav = WebDavService(auth);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => FutureBuilder<List<Map<String, dynamic>>>(
        future: webdav.getFileActivity(file.fileId!),
        builder: (ctx, snapshot) => Container(
          height: MediaQuery.of(ctx).size.height * 0.6,
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Icon(Icons.history, color: AppColors.green800, size: 20),
                const SizedBox(width: 8),
                Expanded(child: Text('Activity — ${file.name}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.heading), overflow: TextOverflow.ellipsis)),
              ]),
              const SizedBox(height: 12),
              const Divider(),
              Expanded(
                child: snapshot.connectionState == ConnectionState.waiting
                    ? const Center(child: CircularProgressIndicator(color: AppColors.green700))
                    : (snapshot.data?.isEmpty ?? true)
                        ? const Center(child: Text('No activity found', style: TextStyle(color: AppColors.muted)))
                        : ListView.builder(
                            itemCount: snapshot.data!.length,
                            itemBuilder: (_, i) {
                              final a = snapshot.data![i];
                              final subject = a['subject'] as String? ?? '';
                              final user = a['user'] as String? ?? '';
                              final dateStr = a['datetime'] as String? ?? '';
                              DateTime? date;
                              try { date = DateTime.parse(dateStr); } catch (_) {}
                              final timeAgo = date != null ? _timeAgo(date) : '';
                              return Padding(
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  CircleAvatar(radius: 16, backgroundColor: AppColors.green700, child: Text(user.isNotEmpty ? user[0].toUpperCase() : '?', style: const TextStyle(color: AppColors.white, fontSize: 12))),
                                  const SizedBox(width: 10),
                                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    Text(subject, style: const TextStyle(fontSize: 13, color: AppColors.heading)),
                                    Text('$user • $timeAgo', style: const TextStyle(fontSize: 11, color: AppColors.muted)),
                                  ])),
                                ]),
                              );
                            },
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _timeAgo(DateTime date) {
    final diff = DateTime.now().difference(date);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${date.day}/${date.month}/${date.year}';
  }

  void _openFile(NcFile file) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FilePreviewScreen(file: file),
      ),
    );
  }

  Future<void> _downloadFile(NcFile file) async {
    setState(() {
      _isDownloading = true;
      _downloadingFileName = file.name;
      _downloadTotalBytes = file.size;
      _downloadedBytes = 0;
    });

    try {
      final auth = context.read<AuthService>();
      final webdav = WebDavService(auth);

      // Download the file first
      final bytes = await webdav.downloadFile(file.path);

      // Check for default download path
      final prefs = await SharedPreferences.getInstance();
      final defaultPath = prefs.getString('default_download_path') ?? '';

      String? savePath;
      final isMobile = Platform.isIOS || Platform.isAndroid;

      if (defaultPath.isNotEmpty) {
        if (isMobile) {
          // On mobile, save to app documents directory
          final dir = await getApplicationDocumentsDirectory();
          savePath = '${dir.path}/${file.name}';
          await File(savePath).writeAsBytes(bytes);
        } else {
          // On desktop, use the chosen default path
          savePath = '$defaultPath/${file.name}';
          await File(savePath).writeAsBytes(bytes);
        }
      } else if (isMobile) {
        // No default — ask user
        savePath = await FilePicker.platform.saveFile(
          dialogTitle: 'Save ${file.name}',
          fileName: file.name,
          bytes: bytes,
        );
        if (savePath == null) {
          if (mounted) setState(() { _isDownloading = false; _downloadingFileName = ''; });
          return;
        }
      } else {
        // Desktop without default path — show save dialog
        savePath = await FilePicker.platform.saveFile(
          dialogTitle: 'Save ${file.name}',
          fileName: file.name,
        );
        if (savePath == null) {
          if (mounted) setState(() { _isDownloading = false; _downloadingFileName = ''; });
          return;
        }
        await File(savePath).writeAsBytes(bytes);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${file.name} saved successfully'), backgroundColor: AppColors.green700),
        );
      }
    } catch (e) {
      // Dismiss progress sheet on error
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Download failed: ${_friendlyError(e)}')));
      }
    } finally {
      if (mounted) setState(() { _isDownloading = false; _downloadingFileName = ''; });
    }
  }

  void _showProgressSheet({required String title, required String fileName, required String detail}) {
    showModalBottomSheet(
      context: context,
      isDismissible: false,
      enableDrag: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  title == 'Uploading' ? Icons.upload_file : Icons.download,
                  color: AppColors.green800,
                  size: 22,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '$title...',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.heading),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              fileName,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: AppColors.heading),
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Text(
              detail,
              style: const TextStyle(fontSize: 12, color: AppColors.muted),
            ),
            const SizedBox(height: 16),
            const ClipRRect(
              borderRadius: BorderRadius.all(Radius.circular(4)),
              child: LinearProgressIndicator(
                color: AppColors.green700,
                backgroundColor: AppColors.grey91,
                minHeight: 6,
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Dismiss', style: TextStyle(color: AppColors.muted)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<String> get _breadcrumbs =>
      _currentPath.split('/').where((p) => p.isNotEmpty).toList();

  String get _title {
    if (widget.searchQuery.isNotEmpty) return 'Search: "${widget.searchQuery}"';
    switch (widget.mode) {
      case FileViewMode.files: return 'My Files';
      case FileViewMode.shared: return _showSharedByMe ? 'Shared by me' : 'Shared with me';
      case FileViewMode.recent: return 'Recent';
      case FileViewMode.starred: return 'Starred';
      case FileViewMode.trash: return 'Trash';
    }
  }

  @override
  Widget build(BuildContext context) {
    final folders = _filteredFiles.where((f) => f.isDirectory).toList();
    final files = _filteredFiles.where((f) => !f.isDirectory).toList();

    return DropTarget(
      onDragEntered: (_) => setState(() => _isDragging = true),
      onDragExited: (_) => setState(() => _isDragging = false),
      onDragDone: (details) async {
        setState(() => _isDragging = false);
        if (details.files.isEmpty || widget.mode != FileViewMode.files) return;
        // Convert dropped files to PlatformFile format and upload
        final platformFiles = <PlatformFile>[];
        for (final xFile in details.files) {
          final file = File(xFile.path);
          if (await file.exists()) {
            final size = await file.length();
            platformFiles.add(PlatformFile(
              name: xFile.name,
              path: xFile.path,
              size: size,
            ));
          }
        }
        if (platformFiles.isNotEmpty) {
          await _uploadFiles(platformFiles);
        }
      },
      child: Stack(
        children: [
          Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Breadcrumb / title + search + view toggle
        LayoutBuilder(
          builder: (context, constraints) {
            final isMobile = constraints.maxWidth < 600;
            return Padding(
              padding: EdgeInsets.fromLTRB(isMobile ? 12 : 24, 12, isMobile ? 12 : 24, 8),
              child: isMobile
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Row 1: Breadcrumb/title + overflow menu
                        Row(
                          children: [
                            Expanded(
                              child: widget.mode == FileViewMode.files && widget.searchQuery.isEmpty
                                  ? SingleChildScrollView(
                                      scrollDirection: Axis.horizontal,
                                      child: _buildBreadcrumb(),
                                    )
                                  : Text(_title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.heading), overflow: TextOverflow.ellipsis),
                            ),
                            if (widget.mode == FileViewMode.files)
                              PopupMenuButton<String>(
                                icon: const Icon(Icons.more_vert, color: AppColors.green800, size: 22),
                                onSelected: (v) {
                                  switch (v) {
                                    case 'grid': setState(() => _isGridView = true);
                                    case 'list': setState(() => _isGridView = false);
                                    case 'upload': _uploadFile();
                                    case 'folder': _createFolder();
                                    case 'newfile': _createFile();
                                  }
                                },
                                itemBuilder: (_) => [
                                  PopupMenuItem(value: _isGridView ? 'list' : 'grid', child: Row(children: [Icon(_isGridView ? Icons.view_list : Icons.grid_view, size: 18, color: AppColors.body), const SizedBox(width: 8), Text(_isGridView ? 'List View' : 'Grid View')])),
                                  const PopupMenuItem(value: 'upload', child: Row(children: [Icon(Icons.upload_file, size: 18, color: AppColors.body), SizedBox(width: 8), Text('Upload File')])),
                                  const PopupMenuItem(value: 'folder', child: Row(children: [Icon(Icons.create_new_folder_outlined, size: 18, color: AppColors.body), SizedBox(width: 8), Text('New Folder')])),
                                  const PopupMenuItem(value: 'newfile', child: Row(children: [Icon(Icons.note_add_outlined, size: 18, color: AppColors.body), SizedBox(width: 8), Text('New File')])),
                                ],
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        // Row 2: Filter search
                        SizedBox(
                          height: 34,
                          child: TextField(
                            onChanged: _onSearch,
                            decoration: InputDecoration(
                              hintText: 'Filter...',
                              prefixIcon: const Icon(Icons.search, size: 18, color: AppColors.muted),
                              filled: true,
                              fillColor: AppColors.grey96,
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
                              contentPadding: EdgeInsets.zero,
                            ),
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        if (widget.mode == FileViewMode.files && widget.searchQuery.isEmpty) ...[
                          Expanded(child: _buildBreadcrumb()),
                        ] else ...[
                          Text(_title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.heading)),
                          const Spacer(),
                        ],
                        // Inline search
                        SizedBox(
                          width: 200,
                          height: 34,
                          child: TextField(
                            onChanged: _onSearch,
                            decoration: InputDecoration(
                              hintText: 'Filter...',
                              prefixIcon: const Icon(Icons.search, size: 18, color: AppColors.muted),
                              filled: true,
                              fillColor: AppColors.grey96,
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
                              contentPadding: EdgeInsets.zero,
                            ),
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                        const SizedBox(width: 12),
                        // View toggle (only for files/shared)
                        if (widget.mode == FileViewMode.files)
                          Container(
                            decoration: BoxDecoration(color: AppColors.grey96, borderRadius: BorderRadius.circular(6)),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _ViewToggleButton(icon: Icons.grid_view, isActive: _isGridView, onTap: () => setState(() => _isGridView = true)),
                                _ViewToggleButton(icon: Icons.view_list, isActive: !_isGridView, onTap: () => setState(() => _isGridView = false)),
                              ],
                            ),
                          ),
                        if (widget.mode == FileViewMode.files) ...[
                          const SizedBox(width: 8),
                          IconButton(
                            icon: const Icon(Icons.upload_file, size: 20, color: AppColors.green800),
                            onPressed: _uploadFile,
                            tooltip: 'Upload',
                          ),
                          IconButton(
                            icon: const Icon(Icons.create_new_folder_outlined, size: 20, color: AppColors.green800),
                            onPressed: _createFolder,
                            tooltip: 'New Folder',
                          ),
                        ],
                      ],
                    ),
            );
          },
        ),

        if (_isUploading)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: AppColors.greenActiveBg,
            child: Row(
              children: [
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.green700)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Uploading $_uploadingFileName ($_uploadedCount/$_uploadTotalCount)',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppColors.heading),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: _uploadTotalBytes > 0 ? _uploadedBytes / _uploadTotalBytes : null,
                          backgroundColor: AppColors.grey91,
                          color: AppColors.green700,
                          minHeight: 4,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _uploadTotalBytes > 0
                            ? '${(_uploadedBytes / (1024 * 1024)).toStringAsFixed(1)} MB / ${(_uploadTotalBytes / (1024 * 1024)).toStringAsFixed(1)} MB'
                            : 'Uploading...',
                        style: const TextStyle(fontSize: 10, color: AppColors.muted),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 16, color: AppColors.muted),
                  onPressed: () => setState(() { _isUploading = false; }),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
          ),

        if (_isDownloading)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: AppColors.greenActiveBg,
            child: Row(
              children: [
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.green700)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Downloading $_downloadingFileName',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppColors.heading),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: null,
                          backgroundColor: AppColors.grey91,
                          color: AppColors.green700,
                          minHeight: 4,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _downloadTotalBytes > 0
                            ? '${(_downloadTotalBytes / (1024 * 1024)).toStringAsFixed(1)} MB'
                            : 'Downloading...',
                        style: const TextStyle(fontSize: 10, color: AppColors.muted),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 16, color: AppColors.muted),
                  onPressed: () => setState(() { _isDownloading = false; }),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
          ),

        // Shared tab toggle (Shared with me / Shared by me)
        if (widget.mode == FileViewMode.shared && widget.searchQuery.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
            child: Row(
              children: [
                _buildSharedToggleButton('Shared with me', !_showSharedByMe, () {
                  setState(() {
                    _showSharedByMe = false;
                    _files = _sharedWithMeFiles;
                    _applyFilterAndSort();
                  });
                }),
                const SizedBox(width: 8),
                _buildSharedToggleButton('Shared by me', _showSharedByMe, () {
                  setState(() {
                    _showSharedByMe = true;
                    _files = _sharedByMeFiles;
                    _applyFilterAndSort();
                  });
                }),
              ],
            ),
          ),

        Expanded(
          child: RefreshIndicator(
            color: AppColors.green700,
            onRefresh: () async {
              try {
                _cacheListenerPaused = true;
                final cache = context.read<DataCacheService>();
                // Refresh current tab immediately
                switch (widget.mode) {
                  case FileViewMode.files:
                    cache.clearFolderCache(_currentPath);
                    await cache.refreshFolder(_currentPath);
                  case FileViewMode.shared:
                    await cache.refreshShared();
                  case FileViewMode.recent:
                    await cache.refreshRecent();
                  case FileViewMode.starred:
                    await cache.refreshStarred();
                  case FileViewMode.trash:
                    await cache.refreshTrash();
                }
              } catch (_) {} finally {
                _cacheListenerPaused = false;
              }
              await _loadFiles();
              // Full refresh in background (won't stack if already running)
              try { context.read<DataCacheService>().refresh(); } catch (_) {}
            },
            child: _isLoading
                ? ListView(children: const [SizedBox(height: 200), Center(child: CircularProgressIndicator(color: AppColors.green700))])
                : _error != null && _files.isEmpty
                    ? ListView(children: [
                        const SizedBox(height: 200),
                        Center(child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_error!, style: const TextStyle(color: AppColors.filePdf)),
                            const SizedBox(height: 12),
                            ElevatedButton(onPressed: _loadFiles, child: const Text('Retry')),
                          ],
                        )),
                      ])
                    : Column(
                        children: [
                          if (_isRefreshing)
                            const LinearProgressIndicator(color: AppColors.green700, backgroundColor: AppColors.grey91, minHeight: 2),
                          Expanded(
                            child: _filteredFiles.isEmpty
                                ? _buildEmptyState()
                                : (widget.mode == FileViewMode.files && _isGridView)
                                    ? _buildGridView(folders, files)
                                    : _buildListView(),
                          ),
                        ],
                      ),
          ),
        ),
      ],
      ),
      // Drag overlay
      if (_isDragging)
        Container(
          color: AppColors.greenActiveBg,
          child: const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.cloud_upload, size: 64, color: AppColors.green700),
                SizedBox(height: 16),
                Text('Drop files here to upload', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.green800)),
              ],
            ),
          ),
        ),
      ],
    ),
    );
  }

  Widget _buildBreadcrumb() {
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        InkWell(
          onTap: () {
            setState(() { _currentPath = '/'; _files = []; _filteredFiles = []; });
            widget.onPathChanged?.call('/');
            _loadFiles();
          },
          child: const Text('My Files', style: TextStyle(fontSize: 14, color: AppColors.green700, fontWeight: FontWeight.w500)),
        ),
        ..._breadcrumbs.asMap().entries.map((entry) {
          final isLast = entry.key == _breadcrumbs.length - 1;
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6),
                child: Icon(Icons.chevron_right, size: 18, color: AppColors.muted),
              ),
              InkWell(
                onTap: isLast ? null : () => _navigateToBreadcrumb(entry.key),
                child: Text(
                  entry.value,
                  style: TextStyle(
                    fontSize: 14,
                    color: isLast ? AppColors.heading : AppColors.green700,
                    fontWeight: isLast ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
            ],
          );
        }),
      ],
    );
  }

  Widget _buildSharedToggleButton(String label, bool isActive, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: isActive ? AppColors.green700 : AppColors.grey96,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: isActive ? Colors.white : AppColors.body,
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    // If phase 2 data hasn't loaded yet for non-files tabs, show loading
    final needsPhase2 = widget.mode == FileViewMode.trash ||
        widget.mode == FileViewMode.shared ||
        widget.mode == FileViewMode.starred;
    if (needsPhase2) {
      try {
        final cache = context.read<DataCacheService>();
        if (!cache.isFullyLoaded) {
          return ListView(children: const [
            SizedBox(height: 150),
            Center(child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: AppColors.green700, strokeWidth: 2),
                SizedBox(height: 16),
                Text('Loading...', style: TextStyle(color: AppColors.muted, fontSize: 14)),
              ],
            )),
          ]);
        }
      } catch (_) {}
    }

    return ListView(children: [const SizedBox(height: 100), Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            widget.mode == FileViewMode.trash ? Icons.delete_outline
                : widget.mode == FileViewMode.starred ? Icons.star_outline
                : Icons.folder_open,
            size: 64,
            color: AppColors.muted,
          ),
          const SizedBox(height: 16),
          Text(
            _searchQuery.isNotEmpty
                ? 'No results for "$_searchQuery"'
                : widget.mode == FileViewMode.trash ? 'Trash is empty'
                : widget.mode == FileViewMode.starred ? 'No starred files'
                : widget.mode == FileViewMode.shared ? 'No shared files'
                : widget.mode == FileViewMode.recent ? 'No recent files'
                : 'This folder is empty',
            style: const TextStyle(color: AppColors.body, fontSize: 16),
          ),
          if (widget.mode == FileViewMode.files && _searchQuery.isEmpty) ...[
            const SizedBox(height: 16),
            ElevatedButton.icon(onPressed: _uploadFile, icon: const Icon(Icons.upload_file), label: const Text('Upload File')),
          ],
        ],
      ),
    )]);
  }

  Widget _buildGridView(List<NcFile> folders, List<NcFile> files) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobile = constraints.maxWidth < 500;
        return ListView(
          padding: EdgeInsets.all(isMobile ? 12 : 24),
          children: [
            if (folders.isNotEmpty) ...[
              const Text('FOLDERS', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.green700, letterSpacing: 0.5)),
              const SizedBox(height: 12),
              Wrap(
                spacing: isMobile ? 10 : 16, runSpacing: isMobile ? 10 : 16,
                children: folders.map((f) => _FolderCard(
                  folder: f,
                  mobileWidth: isMobile ? (constraints.maxWidth - 34) / 2 : null,
                  onTap: () => _navigateToFolder(f),
                  onRename: () => _renameFile(f),
                  onDelete: () => _deleteFile(f),
                  onToggleFavorite: () => _toggleFavorite(f),
                  onShare: () => _shareFile(f),
                  onMove: () => _moveFile(f),
                  onViewActivity: (f.fileId != null && f.fileId!.isNotEmpty) ? () => _showFileActivity(f) : null,
                )).toList(),
              ),
              const SizedBox(height: 24),
            ],
            if (files.isNotEmpty) ...[
              const Text('FILES', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.green700, letterSpacing: 0.5)),
              const SizedBox(height: 12),
              _buildSortableTable(files),
            ],
          ],
        );
      },
    );
  }

  Widget _buildListView() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [_buildSortableTable(_filteredFiles)],
    );
  }

  Widget _buildSortableTable(List<NcFile> items) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobile = constraints.maxWidth < 500;
        return Container(
          decoration: BoxDecoration(
            color: AppColors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.grey91),
          ),
          child: Column(
            children: [
              // Sortable header
              Container(
                padding: EdgeInsets.symmetric(horizontal: isMobile ? 10 : 16, vertical: 12),
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.grey91))),
                child: Row(
                  children: [
                    Expanded(flex: 3, child: _SortableHeader(label: 'NAME', column: SortColumn.name, current: _sortColumn, dir: _sortDir, onTap: _onSort)),
                    if (!isMobile) Expanded(flex: 2, child: _SortableHeader(label: 'OWNER', column: SortColumn.owner, current: _sortColumn, dir: _sortDir, onTap: _onSort)),
                    if (!isMobile) Expanded(flex: 2, child: _SortableHeader(label: 'LAST MODIFIED', column: SortColumn.date, current: _sortColumn, dir: _sortDir, onTap: _onSort)),
                    Expanded(child: _SortableHeader(label: 'SIZE', column: SortColumn.size, current: _sortColumn, dir: _sortDir, onTap: _onSort)),
                    SizedBox(width: isMobile ? 60 : 80, child: const Text('STATUS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.muted, letterSpacing: 0.5))),
                    SizedBox(width: isMobile ? 36 : 48, child: const Text('ACTION', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.muted, letterSpacing: 0.5))),
                  ],
                ),
              ),
              ...items.map((file) => _FileRow(
                file: file,
                isMobile: isMobile,
                onTap: file.isDirectory ? () => _navigateToFolder(file) : (!file.isDirectory && widget.mode != FileViewMode.trash) ? () => _openFile(file) : null,
                onDelete: widget.mode != FileViewMode.trash ? () => _deleteFile(file) : null,
                onDownload: (!file.isDirectory && widget.mode != FileViewMode.trash) ? () => _downloadFile(file) : null,
                onRename: widget.mode != FileViewMode.trash ? () => _renameFile(file) : null,
                onToggleFavorite: widget.mode != FileViewMode.trash ? () => _toggleFavorite(file) : null,
                onSetReminder: (!file.isDirectory && widget.mode != FileViewMode.trash) ? () => _setReminder(file) : null,
                onShare: widget.mode != FileViewMode.trash ? () => _shareFile(file) : null,
                onMove: widget.mode != FileViewMode.trash ? () => _moveFile(file) : null,
                onViewActivity: (file.fileId != null && file.fileId!.isNotEmpty) ? () => _showFileActivity(file) : null,
                onPermanentDelete: widget.mode == FileViewMode.trash ? () => _permanentlyDeleteFromTrash(file) : null,
                onRestore: widget.mode == FileViewMode.trash ? () => _restoreFromTrash(file) : null,
              )),
            ],
          ),
        );
      },
    );
  }
}

class _SortableHeader extends StatelessWidget {
  final String label;
  final SortColumn column;
  final SortColumn current;
  final SortDir dir;
  final ValueChanged<SortColumn> onTap;

  const _SortableHeader({
    required this.label,
    required this.column,
    required this.current,
    required this.dir,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isActive = current == column;
    return InkWell(
      onTap: () => onTap(column),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: isActive ? AppColors.green800 : AppColors.muted,
              letterSpacing: 0.5,
            ),
          ),
          if (isActive)
            Icon(
              dir == SortDir.asc ? Icons.arrow_upward : Icons.arrow_downward,
              size: 14,
              color: AppColors.green800,
            ),
        ],
      ),
    );
  }
}

class _ViewToggleButton extends StatelessWidget {
  final IconData icon;
  final bool isActive;
  final VoidCallback onTap;

  const _ViewToggleButton({required this.icon, required this.isActive, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: isActive ? AppColors.azure17 : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Icon(icon, size: 18, color: isActive ? AppColors.white : AppColors.body),
      ),
    );
  }
}

class _FolderCard extends StatelessWidget {
  final NcFile folder;
  final VoidCallback onTap;
  final VoidCallback? onRename;
  final VoidCallback? onDelete;
  final VoidCallback? onToggleFavorite;
  final VoidCallback? onShare;
  final VoidCallback? onViewActivity;
  final VoidCallback? onMove;
  final double? mobileWidth;

  const _FolderCard({required this.folder, required this.onTap, this.onRename, this.onDelete, this.onToggleFavorite, this.onShare, this.onViewActivity, this.onMove, this.mobileWidth});

  void _showContextMenu(BuildContext context, Offset position) {
    final items = <PopupMenuEntry<String>>[
      if (onRename != null)
        const PopupMenuItem(value: 'rename', child: Row(children: [Icon(Icons.edit, size: 16, color: AppColors.body), SizedBox(width: 8), Text('Rename')])),
      if (onToggleFavorite != null)
        PopupMenuItem(value: 'favorite', child: Row(children: [Icon(folder.isFavorite ? Icons.star : Icons.star_outline, size: 16, color: folder.isFavorite ? AppColors.fileSketch : AppColors.body), const SizedBox(width: 8), Text(folder.isFavorite ? 'Remove from favorites' : 'Add to favorites')])),
      if (onShare != null)
        const PopupMenuItem(value: 'share', child: Row(children: [Icon(Icons.share, size: 16, color: AppColors.body), SizedBox(width: 8), Text('Share')])),
      if (onViewActivity != null) const PopupMenuItem(value: 'activity', child: Row(children: [Icon(Icons.history, size: 16, color: AppColors.body), SizedBox(width: 8), Text('View Activity')])),
      if (onMove != null)
        const PopupMenuItem(value: 'move', child: Row(children: [Icon(Icons.drive_file_move_outline, size: 16, color: AppColors.body), SizedBox(width: 8), Text('Move to...')])),
      if (onDelete != null)
        const PopupMenuItem(value: 'delete', child: Row(children: [Icon(Icons.delete_outline, size: 16, color: AppColors.filePdf), SizedBox(width: 8), Text('Delete', style: TextStyle(color: AppColors.filePdf))])),
    ];
    if (items.isEmpty) return;
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, position.dy),
      items: items,
    ).then((value) {
      if (value == null) return;
      switch (value) {
        case 'rename': onRename?.call();
        case 'favorite': onToggleFavorite?.call();
        case 'share': onShare?.call();
        case 'activity': onViewActivity?.call();
        case 'move': onMove?.call();
        case 'delete': onDelete?.call();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onSecondaryTapUp: (details) => _showContextMenu(context, details.globalPosition),
      onLongPressStart: (details) => _showContextMenu(context, details.globalPosition),
      child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: mobileWidth ?? 200,
        padding: EdgeInsets.all(mobileWidth != null ? 12 : 16),
        decoration: BoxDecoration(
          color: AppColors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.grey91),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.folder, size: 36, color: AppColors.green800),
                if (folder.isFavorite) const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.star, size: 14, color: AppColors.fileSketch)),
                const Spacer(),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_horiz, size: 18, color: AppColors.muted),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onSelected: (v) {
                    switch (v) {
                      case 'rename': onRename?.call();
                      case 'favorite': onToggleFavorite?.call();
                      case 'share': onShare?.call();
                      case 'activity': onViewActivity?.call();
                      case 'move': onMove?.call();
                      case 'delete': onDelete?.call();
                    }
                  },
                  itemBuilder: (_) => [
                    if (onRename != null)
                      const PopupMenuItem(value: 'rename', child: Row(children: [Icon(Icons.edit, size: 16, color: AppColors.body), SizedBox(width: 8), Text('Rename')])),
                    if (onToggleFavorite != null)
                      PopupMenuItem(value: 'favorite', child: Row(children: [Icon(folder.isFavorite ? Icons.star : Icons.star_outline, size: 16, color: folder.isFavorite ? AppColors.fileSketch : AppColors.body), const SizedBox(width: 8), Text(folder.isFavorite ? 'Remove from favorites' : 'Add to favorites')])),
                    if (onShare != null)
                      const PopupMenuItem(value: 'share', child: Row(children: [Icon(Icons.share, size: 16, color: AppColors.body), SizedBox(width: 8), Text('Share')])),
                    if (onViewActivity != null) const PopupMenuItem(value: 'activity', child: Row(children: [Icon(Icons.history, size: 16, color: AppColors.body), SizedBox(width: 8), Text('View Activity')])),
                    if (onMove != null)
                      const PopupMenuItem(value: 'move', child: Row(children: [Icon(Icons.drive_file_move_outline, size: 16, color: AppColors.body), SizedBox(width: 8), Text('Move to...')])),
                    if (onDelete != null)
                      const PopupMenuItem(value: 'delete', child: Row(children: [Icon(Icons.delete_outline, size: 16, color: AppColors.filePdf), SizedBox(width: 8), Text('Delete', style: TextStyle(color: AppColors.filePdf))])),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(folder.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.heading), maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(folder.sizeFormatted, style: const TextStyle(fontSize: 12, color: AppColors.muted)),
          ],
        ),
      ),
    ),
    );
  }
}

class _FileRow extends StatelessWidget {
  final NcFile file;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;
  final VoidCallback? onDownload;
  final VoidCallback? onPermanentDelete;
  final VoidCallback? onRestore;
  final VoidCallback? onRename;
  final VoidCallback? onToggleFavorite;
  final VoidCallback? onSetReminder;
  final VoidCallback? onShare;
  final VoidCallback? onViewActivity;
  final VoidCallback? onMove;
  final bool isMobile;

  const _FileRow({required this.file, this.onTap, this.onDelete, this.onDownload, this.onPermanentDelete, this.onRestore, this.onRename, this.onToggleFavorite, this.onSetReminder, this.onShare, this.onViewActivity, this.onMove, this.isMobile = false});

  void _showContextMenu(BuildContext context, Offset position) {
    final items = <PopupMenuEntry<String>>[
      if (onDownload != null)
        const PopupMenuItem(value: 'download', child: Row(children: [Icon(Icons.download, size: 16, color: AppColors.body), SizedBox(width: 8), Text('Download')])),
      if (onRename != null)
        const PopupMenuItem(value: 'rename', child: Row(children: [Icon(Icons.edit, size: 16, color: AppColors.body), SizedBox(width: 8), Text('Rename')])),
      if (onToggleFavorite != null)
        PopupMenuItem(value: 'favorite', child: Row(children: [Icon(file.isFavorite ? Icons.star : Icons.star_outline, size: 16, color: file.isFavorite ? AppColors.fileSketch : AppColors.body), const SizedBox(width: 8), Text(file.isFavorite ? 'Remove from favorites' : 'Add to favorites')])),
      if (onShare != null)
        const PopupMenuItem(value: 'share', child: Row(children: [Icon(Icons.share, size: 16, color: AppColors.body), SizedBox(width: 8), Text('Share')])),
                    if (onViewActivity != null) const PopupMenuItem(value: 'activity', child: Row(children: [Icon(Icons.history, size: 16, color: AppColors.body), SizedBox(width: 8), Text('View Activity')])),
      if (onMove != null)
        const PopupMenuItem(value: 'move', child: Row(children: [Icon(Icons.drive_file_move_outline, size: 16, color: AppColors.body), SizedBox(width: 8), Text('Move to...')])),
      if (onSetReminder != null)
        const PopupMenuItem(value: 'reminder', child: Row(children: [Icon(Icons.alarm, size: 16, color: AppColors.body), SizedBox(width: 8), Text('Set reminder')])),
      if (onDelete != null)
        const PopupMenuItem(value: 'delete', child: Row(children: [Icon(Icons.delete_outline, size: 16, color: AppColors.filePdf), SizedBox(width: 8), Text('Delete', style: TextStyle(color: AppColors.filePdf))])),
      if (onRestore != null)
        const PopupMenuItem(value: 'restore', child: Row(children: [Icon(Icons.restore, size: 16, color: AppColors.green700), SizedBox(width: 8), Text('Restore')])),
      if (onPermanentDelete != null)
        const PopupMenuItem(value: 'permanent_delete', child: Row(children: [Icon(Icons.delete_forever, size: 16, color: AppColors.filePdf), SizedBox(width: 8), Text('Permanently Delete', style: TextStyle(color: AppColors.filePdf))])),
    ];
    if (items.isEmpty) return;
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, position.dy),
      items: items,
    ).then((value) {
      if (value == null) return;
      switch (value) {
        case 'download': onDownload?.call();
        case 'rename': onRename?.call();
        case 'favorite': onToggleFavorite?.call();
        case 'share': onShare?.call();
        case 'activity': onViewActivity?.call();
        case 'move': onMove?.call();
        case 'reminder': onSetReminder?.call();
        case 'delete': onDelete?.call();
        case 'permanent_delete': onPermanentDelete?.call();
        case 'restore': onRestore?.call();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onSecondaryTapUp: (details) => _showContextMenu(context, details.globalPosition),
      onLongPressStart: (details) => _showContextMenu(context, details.globalPosition),
      child: InkWell(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: isMobile ? 10 : 16, vertical: isMobile ? 8 : 12),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.grey91, width: 0.5))),
        child: Row(
          children: [
            Expanded(
              flex: 3,
              child: Row(
                children: [
                  FileIcon(extension: file.extension, isDirectory: file.isDirectory, size: isMobile ? 28 : 32),
                  SizedBox(width: isMobile ? 8 : 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(child: Text(file.name, style: TextStyle(fontSize: isMobile ? 13 : 14, fontWeight: FontWeight.w500, color: AppColors.heading), overflow: TextOverflow.ellipsis)),
                            if (file.isFavorite) const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.star, size: 14, color: AppColors.fileSketch)),
                          ],
                        ),
                        if (!file.isDirectory && file.extension.isNotEmpty)
                          Text(file.extension.toUpperCase(), style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: getFileTypeColor(file.extension))),
                        if (file.isDirectory)
                          Text(file.sizeFormatted, style: const TextStyle(fontSize: 11, color: AppColors.green700)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (!isMobile)
              Expanded(
                flex: 2,
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 12,
                      backgroundColor: AppColors.green700,
                      child: Text(((file.ownerDisplayName?.isNotEmpty == true ? file.ownerDisplayName : null) ?? 'M')[0].toUpperCase(), style: const TextStyle(fontSize: 10, color: AppColors.white)),
                    ),
                    const SizedBox(width: 6),
                    Expanded(child: Text(file.ownerDisplayName?.isNotEmpty == true ? file.ownerDisplayName! : 'Me', style: const TextStyle(fontSize: 13, color: AppColors.body), overflow: TextOverflow.ellipsis)),
                  ],
                ),
              ),
            if (!isMobile)
              Expanded(
                flex: 2,
                child: Text(
                  file.lastModified != null ? DateFormat('MMM d, y  h:mm a').format(file.lastModified!) : '--',
                  style: const TextStyle(fontSize: 13, color: AppColors.body),
                ),
              ),
            Expanded(
              child: Text(file.sizeFormatted, style: TextStyle(fontSize: isMobile ? 11 : 13, color: AppColors.body)),
            ),
            SizedBox(
              width: isMobile ? 60 : 80,
              child: Builder(builder: (ctx) {
                try {
                  final sync = ctx.watch<SyncService>();
                  final status = sync.getFileStatus(file.path);
                  switch (status) {
                    case FileSyncStatus.synced:
                      return Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.cloud_done, size: 14, color: AppColors.green700),
                        const SizedBox(width: 4),
                        Text('Synced', style: TextStyle(fontSize: isMobile ? 10 : 11, color: AppColors.green700)),
                      ]);
                    case FileSyncStatus.syncing:
                      return Row(mainAxisSize: MainAxisSize.min, children: [
                        const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.green700)),
                        const SizedBox(width: 4),
                        Text('Syncing', style: TextStyle(fontSize: isMobile ? 10 : 11, color: AppColors.green700)),
                      ]);
                    case FileSyncStatus.error:
                      return Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.error_outline, size: 14, color: AppColors.filePdf),
                        const SizedBox(width: 4),
                        Text('Error', style: TextStyle(fontSize: isMobile ? 10 : 11, color: AppColors.filePdf)),
                      ]);
                    case FileSyncStatus.excluded:
                      return Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.block, size: 14, color: AppColors.muted),
                        const SizedBox(width: 4),
                        Text('Excluded', style: TextStyle(fontSize: isMobile ? 10 : 11, color: AppColors.muted)),
                      ]);
                    case FileSyncStatus.pending:
                      return Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.schedule, size: 14, color: AppColors.muted),
                        const SizedBox(width: 4),
                        Text('Pending', style: TextStyle(fontSize: isMobile ? 10 : 11, color: AppColors.muted)),
                      ]);
                  }
                } catch (_) {}
                return const SizedBox.shrink();
              }),
            ),
            SizedBox(
              width: isMobile ? 36 : 48,
              child: PopupMenuButton<String>(
                icon: const Icon(Icons.more_horiz, color: AppColors.muted),
                onSelected: (value) {
                  switch (value) {
                    case 'download': onDownload?.call();
                    case 'rename': onRename?.call();
                    case 'favorite': onToggleFavorite?.call();
                    case 'share': onShare?.call();
                    case 'activity': onViewActivity?.call();
                    case 'move': onMove?.call();
                    case 'reminder': onSetReminder?.call();
                    case 'delete': onDelete?.call();
                    case 'permanent_delete': onPermanentDelete?.call();
                    case 'restore': onRestore?.call();
                  }
                },
                itemBuilder: (_) => [
                  if (onDownload != null)
                    const PopupMenuItem(value: 'download', child: Row(children: [Icon(Icons.download, size: 16, color: AppColors.body), SizedBox(width: 8), Text('Download')])),
                  if (onShare != null)
                    const PopupMenuItem(value: 'share', child: Row(children: [Icon(Icons.share, size: 16, color: AppColors.body), SizedBox(width: 8), Text('Share')])),
                  if (onViewActivity != null) const PopupMenuItem(value: 'activity', child: Row(children: [Icon(Icons.history, size: 16, color: AppColors.body), SizedBox(width: 8), Text('View Activity')])),
                  if (onMove != null)
                    const PopupMenuItem(value: 'move', child: Row(children: [Icon(Icons.drive_file_move_outline, size: 16, color: AppColors.body), SizedBox(width: 8), Text('Move to...')])),
                  if (onRename != null)
                    const PopupMenuItem(value: 'rename', child: Row(children: [Icon(Icons.edit, size: 16, color: AppColors.body), SizedBox(width: 8), Text('Rename')])),
                  if (onToggleFavorite != null)
                    PopupMenuItem(value: 'favorite', child: Row(children: [Icon(file.isFavorite ? Icons.star : Icons.star_outline, size: 16, color: file.isFavorite ? AppColors.fileSketch : AppColors.body), const SizedBox(width: 8), Text(file.isFavorite ? 'Remove from favorites' : 'Add to favorites')])),
                  if (onSetReminder != null)
                    const PopupMenuItem(value: 'reminder', child: Row(children: [Icon(Icons.alarm, size: 16, color: AppColors.body), SizedBox(width: 8), Text('Set reminder')])),
                  if (onDelete != null)
                    const PopupMenuItem(value: 'delete', child: Row(children: [Icon(Icons.delete_outline, size: 16, color: AppColors.filePdf), SizedBox(width: 8), Text('Delete', style: TextStyle(color: AppColors.filePdf))])),
                  if (onRestore != null)
                    const PopupMenuItem(value: 'restore', child: Row(children: [Icon(Icons.restore, size: 16, color: AppColors.green700), SizedBox(width: 8), Text('Restore')])),
                  if (onPermanentDelete != null)
                    const PopupMenuItem(value: 'permanent_delete', child: Row(children: [Icon(Icons.delete_forever, size: 16, color: AppColors.filePdf), SizedBox(width: 8), Text('Permanently Delete', style: TextStyle(color: AppColors.filePdf))])),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
    );
  }
}

class _ReminderChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _ReminderChip({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      onPressed: onTap,
      backgroundColor: AppColors.grey96,
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    );
  }
}

/// Autocomplete text field for the share sheet.
/// Queries the Nextcloud autocomplete API with a 300ms debounce.
class _ShareAutocompleteField extends StatefulWidget {
  final TextEditingController controller;
  final String serverUrl;
  final String basicAuth;
  final ValueChanged<int>? onShareTypeSelected;

  const _ShareAutocompleteField({
    required this.controller,
    required this.serverUrl,
    required this.basicAuth,
    this.onShareTypeSelected,
  });

  @override
  State<_ShareAutocompleteField> createState() => _ShareAutocompleteFieldState();
}

class _ShareAutocompleteFieldState extends State<_ShareAutocompleteField> {
  Timer? _debounce;
  List<Map<String, dynamic>> _suggestions = [];
  bool _showSuggestions = false;
  bool _suppressSearch = false;
  bool _loadedRecommended = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    widget.controller.removeListener(_onTextChanged);
    super.dispose();
  }

  void _onTextChanged() {
    if (_suppressSearch) return;
    _debounce?.cancel();
    final query = widget.controller.text.trim();
    if (query.isEmpty) {
      setState(() { _suggestions = []; _showSuggestions = false; });
      return;
    }
    if (query.length < 2) {
      setState(() { _suggestions = []; _showSuggestions = false; });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _fetchSuggestions(query);
    });
  }

  Future<void> _loadRecommended() async {
    try {
      final url = Uri.parse(
        '${widget.serverUrl}/ocs/v2.php/apps/files_sharing/api/v1/sharees_recommended?itemType=file&format=json',
      );
      final response = await WebDavService.sharedHttpClient.get(url, headers: {
        'Authorization': widget.basicAuth,
        'OCS-APIRequest': 'true',
      });
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final results = _parseSharees(data['ocs']?['data'] as Map<String, dynamic>? ?? {});
        if (mounted) {
          setState(() {
            _suggestions = results;
            _showSuggestions = results.isNotEmpty;
            _loadedRecommended = true;
          });
        }
      }
    } catch (_) {}
  }

  void _onFocus() {
    _suppressSearch = false;
    if (widget.controller.text.isEmpty) {
      _loadRecommended();
    }
  }

  List<Map<String, dynamic>> _parseSharees(Map<String, dynamic> shareeData) {
    final results = <Map<String, dynamic>>[];
    final categories = ['users', 'emails', 'remotes', 'groups', 'remote_groups', 'rooms'];
    final categoryLabels = {
      'users': 'User', 'groups': 'Group', 'rooms': 'Conversation',
      'emails': 'Email', 'remotes': 'Federated', 'remote_groups': 'Remote group',
    };
    for (final category in categories) {
      for (final section in [shareeData, shareeData['exact'] as Map? ?? {}]) {
        final items = section[category] as List? ?? [];
        for (final item in items) {
          final id = item['value']?['shareWith'] ?? '';
          if (id.isEmpty || results.any((r) => r['id'] == id)) continue;
          results.add({
            'id': id,
            'label': item['label'] ?? id,
            'shareType': item['value']?['shareType'] ?? 0,
            'subline': categoryLabels[category] ?? '',
          });
        }
      }
    }
    return results;
  }

  Future<void> _fetchSuggestions(String query) async {
    try {
      final url = Uri.parse(
        '${widget.serverUrl}/ocs/v2.php/apps/files_sharing/api/v1/sharees?search=${Uri.encodeQueryComponent(query)}&itemType=file&format=json&perPage=20',
      );
      final response = await WebDavService.sharedHttpClient.get(url, headers: {
        'Authorization': widget.basicAuth,
        'OCS-APIRequest': 'true',
      });
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final results = _parseSharees(data['ocs']?['data'] as Map<String, dynamic>? ?? {});
        if (mounted) {
          setState(() {
            _suggestions = results;
            _showSuggestions = results.isNotEmpty;
          });
        }
      }
    } catch (e) {
      debugPrint('Autocomplete error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: widget.controller,
          onTap: _onFocus,
          decoration: InputDecoration(
            hintText: 'Username or email',
            filled: true,
            fillColor: AppColors.grey96,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            suffixIcon: widget.controller.text.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear, size: 16),
                    onPressed: () {
                      widget.controller.clear();
                      setState(() { _suggestions = []; _showSuggestions = false; });
                    },
                  )
                : null,
          ),
          style: const TextStyle(fontSize: 14),
        ),
        if (_showSuggestions && _suggestions.isNotEmpty)
          Container(
            constraints: const BoxConstraints(maxHeight: 200),
            margin: const EdgeInsets.only(top: 4),
            decoration: BoxDecoration(
              color: AppColors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.grey91),
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 8, offset: const Offset(0, 2))],
            ),
            child: ListView.builder(
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              itemCount: _suggestions.length,
              itemBuilder: (context, index) {
                final item = _suggestions[index];
                final id = item['id'] as String? ?? '';
                final label = item['label'] as String? ?? id;
                final subline = item['subline'] as String? ?? '';
                final shareType = item['shareType'] as int? ?? 0;
                final icon = shareType == 4 ? Icons.email_outlined
                    : shareType == 6 ? Icons.cloud_outlined
                    : shareType == 10 ? Icons.chat_outlined
                    : shareType == 1 ? Icons.group_outlined
                    : Icons.person_outline;
                return ListTile(
                  dense: true,
                  leading: Icon(icon, size: 20, color: AppColors.azure47),
                  title: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                  subtitle: Text(subline.isNotEmpty ? '$subline — $id' : id, style: const TextStyle(fontSize: 11, color: AppColors.muted)),
                  onTap: () {
                    _suppressSearch = true;
                    widget.controller.text = id;
                    widget.controller.selection = TextSelection.fromPosition(
                      TextPosition(offset: id.length),
                    );
                    widget.onShareTypeSelected?.call(shareType);
                    setState(() { _suggestions = []; _showSuggestions = false; });
                  },
                );
              },
            ),
          ),
      ],
    );
  }
}

/// Dialog for choosing a destination folder when moving files.
class _MoveToDialog extends StatefulWidget {
  final WebDavService webdav;
  final String fileName;
  final String filePath; // Path of the item being moved (to exclude from list)
  const _MoveToDialog({required this.webdav, required this.fileName, required this.filePath});

  @override
  State<_MoveToDialog> createState() => _MoveToDialogState();
}

class _MoveToDialogState extends State<_MoveToDialog> {
  String _currentPath = '/';
  List<NcFile> _folders = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final items = await widget.webdav.listFiles(_currentPath);
      _folders = items.where((f) => f.isDirectory && f.path != widget.filePath).toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  void _goUp() {
    final parts = _currentPath.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return;
    parts.removeLast();
    _currentPath = parts.isEmpty ? '/' : '/${parts.join('/')}';
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Move "${widget.fileName}" to...'),
      content: SizedBox(
        width: 400,
        height: 400,
        child: Column(
          children: [
            // Current path + back button
            Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  if (_currentPath != '/')
                    IconButton(
                      icon: const Icon(Icons.arrow_back, size: 20),
                      onPressed: _goUp,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    ),
                  const Icon(Icons.folder_open, size: 18, color: AppColors.green800),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _currentPath == '/' ? 'Root' : _currentPath,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.heading),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator(color: AppColors.green700, strokeWidth: 2))
                  : _folders.isEmpty
                      ? const Center(child: Text('No subfolders', style: TextStyle(color: AppColors.muted, fontSize: 13)))
                      : ListView.builder(
                          itemCount: _folders.length,
                          itemBuilder: (_, i) {
                            final f = _folders[i];
                            return ListTile(
                              dense: true,
                              leading: const Icon(Icons.folder, size: 20, color: AppColors.green800),
                              title: Text(f.name, style: const TextStyle(fontSize: 13)),
                              onTap: () {
                                _currentPath = f.path;
                                _load();
                              },
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton.icon(
          onPressed: () => Navigator.pop(context, _currentPath),
          icon: const Icon(Icons.check, size: 18),
          label: const Text('Move Here'),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.green800,
            foregroundColor: AppColors.white,
          ),
        ),
      ],
    );
  }
}
