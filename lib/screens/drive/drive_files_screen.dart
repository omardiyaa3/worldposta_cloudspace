// drive_files_screen.dart — browse + file operations against the new Drive.
//
// Handles all list modes (files/recent/starred/shared/trash). Files mode is a
// UUID-addressed tree: navigate by parent_id, breadcrumbs from GET /files/{id}/path.
// Operations go through the active account's DriveApi so requests always carry
// the right token (isolation).

import 'dart:io';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mime/mime.dart';
import 'package:provider/provider.dart';

import '../../config/theme.dart';
import '../../models/drive_file.dart';
import '../../services/drive/drive_account_manager.dart';
import '../../services/drive/drive_api.dart';
import '../../services/drive/drive_cache.dart';
import '../../services/drive/drive_client.dart';
import '../../widgets/file_type_badge.dart';
import 'drive_file_preview.dart';
import 'drive_file_sheets.dart';
import 'drive_office_editor.dart';
import 'drive_share_sheet.dart';

enum DriveViewMode { files, recent, starred, shared, trash }

enum _SortCol { name, date, size }

class DriveFilesScreen extends StatefulWidget {
  final DriveViewMode mode;
  final ValueChanged<Future<void> Function()>? onRefreshReady;
  final ValueChanged<VoidCallback>? onNewMenuReady; // hands the shell a "New" trigger
  const DriveFilesScreen({super.key, this.mode = DriveViewMode.files, this.onRefreshReady, this.onNewMenuReady});

  @override
  State<DriveFilesScreen> createState() => _DriveFilesScreenState();
}

class _DriveFilesScreenState extends State<DriveFilesScreen> {
  // Current folder (files mode). null = root.
  String? _parentId;
  DriveFile? _currentFolder; // the folder we've drilled into (for its permission)
  List<DrivePathNode> _crumbs = [];
  List<DriveFile> _files = [];
  bool _loading = true;
  bool _busy = false;
  String? _error;
  bool _showSharedByMe = false;

  // Upload progress (tus).
  bool _uploading = false;
  bool _uploadCancel = false;
  String _uploadName = '';
  int _uploadSent = 0;
  int _uploadTotal = 0;
  int _uploadIndex = 0;
  int _uploadCount = 0;

  // View + sort + selection + drag.
  bool _isGrid = true;
  _SortCol _sortCol = _SortCol.name;
  bool _sortAsc = true;
  final Set<String> _selected = {};
  bool _selectMode = false; // header "Select" toggled on (checkboxes visible)
  bool get _selecting => _selectMode || _selected.isNotEmpty;
  bool _dragging = false;

  void _exitSelect() => setState(() { _selectMode = false; _selected.clear(); });
  void _toggleSelectMode() => setState(() { if (_selectMode || _selected.isNotEmpty) { _selectMode = false; _selected.clear(); } else { _selectMode = true; } });

  DriveApi get _api => context.read<DriveAccountManager>().activeApi!;
  DriveCache get _cache => context.read<DriveCache>();

  bool get _isTrash => widget.mode == DriveViewMode.trash;
  bool get _isFiles => widget.mode == DriveViewMode.files;

  // Permission helpers. For items you own (your own Files/Recent/Starred) the
  // server sends no role → myRole/canEdit are null → treat as owner (all actions).
  // For items shared WITH you, they reflect your granted role, so we hide actions
  // your role can't perform (e.g. a viewer sees no rename/move/delete/share).
  bool _canWrite(DriveFile f) => f.canEdit ?? true; // editor+  → rename/move/delete
  bool _canManage(DriveFile f) => (f.myRole?.rank ?? 99) >= DriveRole.manager.rank; // manager+ → share/expiration

  // Whether the CURRENT location accepts new files/folders. Inside a folder we
  // honour THAT folder's permission — even in "My Files", because folders shared
  // with you (incl. view-only) show up there too. At a list root: your own drive
  // (Files) yes; the Shared/Recent/Starred/Trash lists never. This hides
  // Upload/New/drag-drop when you're viewing a folder you can't write to.
  bool get _canCreateHere {
    if (_currentFolder != null) return _currentFolder!.canEdit ?? true;
    return _isFiles;
  }

  @override
  void initState() {
    super.initState();
    _load();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onRefreshReady?.call(_refresh);
      widget.onNewMenuReady?.call(_showNewMenu);
    });
  }

  /// The "New" menu (Upload / New Folder / New File) — shared by the header
  /// buttons and the sidebar "New" button. Acts on the current folder, so it's
  /// blocked when you can't write there (e.g. a view-only shared folder).
  void _showNewMenu() {
    if (!_canCreateHere) {
      _snack('You don\'t have permission to add items in this folder.', ok: false);
      return;
    }
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.upload_file, color: AppColors.green700),
            title: const Text('Upload File'),
            onTap: () { Navigator.pop(ctx); _upload(); },
          ),
          ListTile(
            leading: const Icon(Icons.create_new_folder_outlined, color: AppColors.green700),
            title: const Text('New Folder'),
            onTap: () { Navigator.pop(ctx); _createFolder(); },
          ),
          ListTile(
            leading: const Icon(Icons.note_add_outlined, color: AppColors.green700),
            title: const Text('New File'),
            onTap: () { Navigator.pop(ctx); _createFile(); },
          ),
        ]),
      ),
    );
  }

  String _friendly(Object e) {
    if (e is DriveException) {
      if (e.isAuth) return 'Your session expired. Please sign in again.';
      if (e.isNotFound) return 'Not found.';
      if (e.isQuota) return 'Storage is full.';
      if (e.code == 'permission_denied') return 'You don\'t have permission to do that.';
      return e.message;
    }
    final s = e.toString();
    if (s.contains('SocketException') || s.contains('ClientException')) {
      return 'Connection lost. Check your internet and try again.';
    }
    return s.length > 100 ? '${s.substring(0, 100)}…' : s;
  }

  Future<void> _load() async {
    if (mounted) setState(() => _error = null);
    try {
      List<DriveFile> items;
      // Once drilled into a folder (from ANY mode — e.g. opening a folder that's
      // shared with you), list that folder's contents by parent id rather than the
      // mode-specific list. The server enforces visibility, so you only see what
      // you're allowed to.
      if (!_isFiles && _parentId != null) {
        items = await _cache.getFolder(_parentId);
        if (mounted) setState(() { _files = _sorted(items); _loading = false; });
        return;
      }
      switch (widget.mode) {
        case DriveViewMode.files:
          items = await _cache.getFolder(_parentId);
        case DriveViewMode.recent:
          items = _cache.recentFiles;
          if (items.isEmpty && !_cache.isFullyLoaded) items = await _api.listRecent();
        case DriveViewMode.starred:
          items = _cache.starredFiles;
          if (items.isEmpty && !_cache.isFullyLoaded) items = await _api.listStarred();
        case DriveViewMode.shared:
          items = _showSharedByMe ? _cache.sharedByMe : _cache.sharedWithMe;
          if (items.isEmpty && !_cache.isFullyLoaded) {
            items = _showSharedByMe ? await _api.listSharedByMe() : await _api.listSharedWithMe();
          }
        case DriveViewMode.trash:
          items = _cache.trashFiles;
          if (items.isEmpty && !_cache.isFullyLoaded) items = await _api.listTrash();
      }
      if (mounted) {
        setState(() {
          _files = _sorted(items);
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          if (_files.isEmpty) _error = _friendly(e);
          _loading = false;
        });
      }
    }
  }

  // Star state is client-side only (the file list doesn't return it), so mark
  // items by cross-referencing the cached /starred set. The Starred view's own
  // items are all starred by definition.
  List<DriveFile> _markStarred(List<DriveFile> items) {
    if (widget.mode == DriveViewMode.starred) {
      return [for (final f in items) f.isStarred ? f : f.copyWith(isStarred: true)];
    }
    final ids = _cache.starredFiles.map((f) => f.id).toSet();
    if (ids.isEmpty) return items;
    return [for (final f in items) ids.contains(f.id) ? f.copyWith(isStarred: true) : f];
  }

  List<DriveFile> _sorted(List<DriveFile> items) {
    items = _markStarred(items);
    final list = List<DriveFile>.from(items);
    list.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1; // dirs first
      int cmp;
      switch (_sortCol) {
        case _SortCol.name:
          cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case _SortCol.date:
          cmp = (a.updatedAt ?? DateTime(2000)).compareTo(b.updatedAt ?? DateTime(2000));
        case _SortCol.size:
          cmp = a.sizeBytes.compareTo(b.sizeBytes);
      }
      return _sortAsc ? cmp : -cmp;
    });
    return list;
  }

  void _setSort(_SortCol col) {
    setState(() {
      if (_sortCol == col) {
        _sortAsc = !_sortAsc;
      } else {
        _sortCol = col;
        _sortAsc = true;
      }
      _files = _sorted(_files);
    });
  }

  void _toggleSelect(String id) => setState(() {
        _selected.contains(id) ? _selected.remove(id) : _selected.add(id);
      });

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      switch (widget.mode) {
        case DriveViewMode.files:
          _cache.clearFolderCache(_parentId);
          await _cache.refreshFolder(_parentId);
        case DriveViewMode.recent:
          await _cache.refreshRecent();
        case DriveViewMode.starred:
          await _cache.refreshStarred();
        case DriveViewMode.shared:
          await _cache.refreshShared();
        case DriveViewMode.trash:
          await _cache.refreshTrash();
      }
    } catch (_) {}
    await _load();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _openFolder(DriveFile folder) async {
    final append = [..._crumbs, DrivePathNode(id: folder.id, name: folder.name, isDirectory: true)];
    setState(() {
      _parentId = folder.id;
      _currentFolder = folder;
      _crumbs = append;
      _files = [];
      _loading = true;
    });
    // In Files mode use the server path (authoritative, trims to visible
    // ancestors). In other modes (Shared/Recent/Starred) the server path would
    // reference the owner's tree, which you can't navigate, so we just append the
    // opened folder to the local trail (rooted at the mode's list).
    if (_isFiles) {
      try {
        _crumbs = await _api.filePath(folder.id);
      } catch (_) {/* keep the appended trail */}
    }
    await _load();
  }

  Future<void> _navigateToRoot() async {
    setState(() {
      _parentId = null;
      _currentFolder = null;
      _crumbs = [];
      _files = [];
      _loading = true;
    });
    await _load();
  }

  Future<void> _navigateToCrumb(int index) async {
    final node = _crumbs[index];
    setState(() {
      _parentId = node.id;
      _currentFolder = null; // refreshed from the server below (crumbs lack permission)
      _crumbs = _crumbs.sublist(0, index + 1);
      _files = [];
      _loading = true;
    });
    try { _currentFolder = await _api.fileDetail(node.id); } catch (_) {}
    await _load();
  }

  // ── operations ──────────────────────────────────────────────────────────

  Future<void> _snack(String msg, {bool ok = true}) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: ok ? AppColors.green700 : AppColors.filePdf),
    );
  }

  Future<void> _createFolder() async {
    final name = await _promptName('New Folder', 'Folder name');
    if (name == null || name.isEmpty) return;
    try {
      await _api.createFolder(name, parentId: _parentId);
      _cache.clearFolderCache(_parentId);
      await _load();
      _snack('Folder "$name" created');
    } catch (e) {
      _snack('Failed: ${_friendly(e)}', ok: false);
    }
  }

  Future<void> _upload() async {
    // withData:false → we get a file path and stream it through tus (any size).
    final result = await FilePicker.platform.pickFiles(withData: false, allowMultiple: true);
    if (result == null || result.files.isEmpty) return;
    await _uploadPaths([for (final f in result.files) if (f.path != null) (path: f.path!, name: f.name)]);
  }

  Future<void> _createFile() async {
    final result = await showDialog<({String name, String kind})>(
      context: context,
      builder: (ctx) {
        var kind = 'txt';
        final ctrl = TextEditingController(text: 'Untitled');
        const kinds = {'txt': 'Text (.txt)', 'docx': 'Document (.docx)', 'xlsx': 'Spreadsheet (.xlsx)', 'pptx': 'Presentation (.pptx)', 'md': 'Markdown (.md)'};
        return StatefulBuilder(
          builder: (ctx, setD) => AlertDialog(
            scrollable: true, // keep actions anchored when the keyboard opens
            title: const Text('New File'),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              ...kinds.entries.map((e) => ListTile(
                    dense: true,
                    leading: Icon(kind == e.key ? Icons.radio_button_checked : Icons.radio_button_unchecked, size: 20, color: kind == e.key ? AppColors.green800 : AppColors.muted),
                    title: Text(e.value, style: const TextStyle(fontSize: 14)),
                    onTap: () => setD(() => kind = e.key),
                  )),
              const SizedBox(height: 8),
              TextField(controller: ctrl, autofocus: true, decoration: InputDecoration(labelText: 'File name', suffixText: '.$kind')),
            ]),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              ElevatedButton(onPressed: () => Navigator.pop(ctx, (name: ctrl.text.trim(), kind: kind)), child: const Text('Create')),
            ],
          ),
        );
      },
    );
    if (result == null || result.name.isEmpty) return;
    try {
      final f = await _api.createFile(result.kind, name: result.name, parentId: _parentId);
      _cache.clearFolderCache(_parentId);
      await _load();
      _snack('Created "${f.name}"');
      if (mounted && !f.isDirectory) _open(f); // office → Collabora, text → editor
    } catch (e) {
      _snack('Failed: ${_friendly(e)}', ok: false);
    }
  }

  Future<void> _uploadPaths(List<({String path, String name})> files) async {
    if (files.isEmpty || _uploading) return;
    setState(() {
      _uploading = true;
      _uploadCancel = false;
      _uploadCount = files.length;
    });
    int done = 0;
    for (var i = 0; i < files.length; i++) {
      if (_uploadCancel) break;
      final f = files[i];
      int size = 0;
      try {
        size = await File(f.path).length();
      } catch (_) {}
      setState(() {
        _uploadIndex = i;
        _uploadName = f.name;
        _uploadSent = 0;
        _uploadTotal = size;
      });
      try {
        await _api.uploadViaTus(
          localPath: f.path,
          filename: f.name,
          parentId: _parentId,
          contentType: lookupMimeType(f.name) ?? 'application/octet-stream',
          onProgress: (s, t) {
            if (mounted) setState(() { _uploadSent = s; _uploadTotal = t; });
          },
          isCancelled: () => _uploadCancel,
        );
        done++;
      } on DriveException catch (e) {
        if (e.code == 'cancelled') break;
        await _snack('Upload failed for ${f.name}: ${_friendly(e)}', ok: false);
      } catch (e) {
        await _snack('Upload failed for ${f.name}: ${_friendly(e)}', ok: false);
      }
    }
    if (mounted) setState(() { _uploading = false; _uploadName = ''; });
    // tus finalises asynchronously — refresh now and again shortly after so the
    // new files appear once the server commits them.
    _cache.clearFolderCache(_parentId);
    await _load();
    if (done > 0) {
      await _snack(_uploadCancel ? 'Upload cancelled ($done uploaded)' : 'Uploaded $done file${done == 1 ? '' : 's'}');
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) { _cache.clearFolderCache(_parentId); _load(); }
      });
    }
  }

  // ── bulk actions (multi-select) ─────────────────────────────────────────

  List<DriveFile> get _selectedFiles => _files.where((f) => _selected.contains(f.id)).toList();

  Future<void> _bulkDelete() async {
    final sel = _selectedFiles;
    if (sel.isEmpty) return;
    final ok = await _confirm('Delete ${sel.length} item${sel.length == 1 ? '' : 's'}?', 'They move to trash.', 'Delete');
    if (!ok) return;
    for (final f in sel) {
      try { await _api.trash(f.id); } catch (_) {}
    }
    if (_isFiles) _cache.clearFolderCache(_parentId);
    setState(() { _files.removeWhere((f) => _selected.contains(f.id)); _selected.clear(); });
    _snack('${sel.length} moved to trash');
  }

  Future<void> _bulkDownload() async {
    final sel = _selectedFiles.where((f) => !f.isDirectory).toList();
    setState(() => _selected.clear());
    for (final f in sel) {
      await _download(f);
    }
  }

  Future<void> _bulkStar() async {
    final sel = _selectedFiles;
    for (final f in sel) {
      try { f.isStarred ? await _api.unstar(f.id) : await _api.star(f.id); } catch (_) {}
    }
    await _cache.refreshStarred();
    setState(() => _selected.clear());
    await _refresh();
  }

  void _selectAll() => setState(() => _selected
    ..clear()
    ..addAll(_files.map((f) => f.id)));

  Future<void> _bulkPurge() async {
    final sel = _selectedFiles;
    if (sel.isEmpty) return;
    final ok = await _confirm('Permanently delete ${sel.length} item${sel.length == 1 ? '' : 's'}?', 'This cannot be undone.', 'Delete forever');
    if (!ok) return;
    for (final f in sel) { try { await _api.purgeTrash(f.id); } catch (_) {} }
    setState(() { _files.removeWhere((f) => _selected.contains(f.id)); _selected.clear(); });
    _snack('${sel.length} permanently deleted');
  }

  Future<void> _bulkRestore() async {
    final sel = _selectedFiles;
    if (sel.isEmpty) return;
    for (final f in sel) { try { await _api.restoreTrash(f.id); } catch (_) {} }
    setState(() { _files.removeWhere((f) => _selected.contains(f.id)); _selected.clear(); });
    _snack('${sel.length} restored');
  }

  Future<void> _emptyTrash() async {
    if (_files.isEmpty) return;
    final n = _files.length;
    final ok = await _confirm('Empty trash?', 'Permanently delete all $n item${n == 1 ? '' : 's'}. This cannot be undone.', 'Empty Trash');
    if (!ok) return;
    setState(() => _busy = true);
    final ids = _files.map((f) => f.id).toList();
    for (final id in ids) { try { await _api.purgeTrash(id); } catch (_) {} }
    if (mounted) setState(() { _files.clear(); _selected.clear(); _busy = false; });
    _snack('Trash emptied');
  }

  Future<void> _rename(DriveFile f) async {
    final name = await _promptName('Rename', 'New name', initial: f.name);
    if (name == null || name.isEmpty || name == f.name) return;
    try {
      await _api.rename(f.id, name);
      if (_isFiles) _cache.clearFolderCache(_parentId);
      await _refresh();
      _snack('Renamed to "$name"');
    } catch (e) {
      _snack('Rename failed: ${_friendly(e)}', ok: false);
    }
  }

  Future<void> _delete(DriveFile f) async {
    final ok = await _confirm('Delete "${f.name}"?',
        f.isDirectory ? 'The folder and its contents move to trash.' : 'This file moves to trash.', 'Delete');
    if (!ok) return;
    try {
      await _api.trash(f.id);
      setState(() => _files.removeWhere((x) => x.id == f.id));
      if (_isFiles) _cache.clearFolderCache(_parentId);
      _cache.logLocalActivity('you deleted ${f.name}', resourceId: f.id);
      _snack('"${f.name}" moved to trash');
    } catch (e) {
      _snack('Delete failed: ${_friendly(e)}', ok: false);
    }
  }

  Future<void> _toggleStar(DriveFile f) async {
    final nowStarred = !f.isStarred;
    // Optimistic: star state is client-side only (the file list doesn't carry it),
    // so update the row immediately for instant feedback rather than reloading.
    void setStar(bool v) {
      final i = _files.indexWhere((x) => x.id == f.id);
      if (i >= 0) setState(() => _files[i] = _files[i].copyWith(isStarred: v));
    }
    setStar(nowStarred);
    try {
      if (nowStarred) {
        await _api.star(f.id);
      } else {
        await _api.unstar(f.id);
      }
      await _cache.refreshStarred();
      // In the Starred view, an unstar removes the row.
      if (widget.mode == DriveViewMode.starred && !nowStarred && mounted) {
        setState(() => _files.removeWhere((x) => x.id == f.id));
      }
    } catch (e) {
      if (mounted) setStar(!nowStarred); // revert on failure
      _snack(_friendly(e), ok: false);
    }
  }

  Future<void> _restore(DriveFile f) async {
    try {
      await _api.restoreTrash(f.id);
      setState(() => _files.removeWhere((x) => x.id == f.id));
      _snack('"${f.name}" restored');
    } catch (e) {
      _snack('Restore failed: ${_friendly(e)}', ok: false);
    }
  }

  Future<void> _purge(DriveFile f) async {
    final ok = await _confirm('Permanently delete "${f.name}"?', 'This cannot be undone.', 'Delete forever');
    if (!ok) return;
    try {
      await _api.purgeTrash(f.id);
      setState(() => _files.removeWhere((x) => x.id == f.id));
      _snack('"${f.name}" permanently deleted');
    } catch (e) {
      _snack('Delete failed: ${_friendly(e)}', ok: false);
    }
  }

  Future<void> _download(DriveFile f) async {
    setState(() => _busy = true);
    try {
      final bytes = await _api.download(f.id);
      final isMobile = Platform.isIOS || Platform.isAndroid;
      String? path = await FilePicker.platform.saveFile(
        dialogTitle: 'Save ${f.name}',
        fileName: f.name,
        bytes: isMobile ? bytes : null,
      );
      if (path == null) return;
      if (!isMobile) await File(path).writeAsBytes(bytes);
      _snack('"${f.name}" saved');
    } catch (e) {
      _snack('Download failed: ${_friendly(e)}', ok: false);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static const _officeExts = {'docx', 'xlsx', 'pptx', 'doc', 'xls', 'ppt', 'odt', 'ods', 'odp'};

  void _open(DriveFile f) {
    if (f.isDirectory) {
      _openFolder(f);
      return;
    }
    // Office files → Collabora editor (like the Drive); everything else → preview.
    if (_officeExts.contains(f.extension)) {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => DriveOfficeEditor(file: f)));
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => DriveFilePreview(file: f)));
  }

  Future<void> _share(DriveFile f) => showDriveShareSheet(context, f);

  void _versions(DriveFile f) => showDriveVersionsSheet(context, f);
  void _comments(DriveFile f) => showDriveCommentsSheet(context, f);
  void _activity(DriveFile f) => showDriveActivitySheet(context, f);
  Future<void> _expiration(DriveFile f) => showDriveExpirationDialog(context, f, onChanged: () {
        if (_isFiles) _cache.clearFolderCache(_parentId);
        _refresh();
      });

  Future<void> _move(DriveFile f) async {
    // Picker pops 'root' for the drive root, a uuid for a folder, or null on cancel.
    final dest = await showDialog<String>(
      context: context,
      builder: (_) => _MovePicker(api: _api, movingId: f.id, fileName: f.name),
    );
    if (dest == null) return; // cancelled
    try {
      await _api.move(f.id, parentId: dest == 'root' ? null : dest);
      setState(() => _files.removeWhere((x) => x.id == f.id));
      if (_isFiles) _cache.clearFolderCache(_parentId);
      _snack('Moved "${f.name}"');
    } catch (e) {
      _snack('Move failed: ${_friendly(e)}', ok: false);
    }
  }

  Future<void> _copy(DriveFile f) async {
    try {
      await _api.copy(f.id, parentId: _parentId);
      if (_isFiles) _cache.clearFolderCache(_parentId);
      await _refresh();
      _snack('Copied "${f.name}"');
    } catch (e) {
      _snack('Copy failed: ${_friendly(e)}', ok: false);
    }
  }

  // ── small dialogs ─────────────────────────────────────────────────────────

  Future<String?> _promptName(String title, String hint, {String? initial}) {
    final c = TextEditingController(text: initial ?? '');
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // keep actions anchored when the keyboard opens
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('OK')),
        ],
      ),
    );
  }

  Future<bool> _confirm(String title, String body, String action) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.filePdf),
            child: Text(action),
          ),
        ],
      ),
    );
    return r == true;
  }

  // ── build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Repaint when the cache updates (background refreshes, phase-2 loads).
    context.watch<DriveCache>();
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(),
        if (_selecting) _selectionBar(),
        if (_uploading) _uploadBanner(),
        if (_busy && !_uploading) const LinearProgressIndicator(color: AppColors.green700, backgroundColor: AppColors.grey91, minHeight: 2),
        Expanded(
          child: RefreshIndicator(
            color: AppColors.green700,
            onRefresh: _refresh,
            child: _loading
                ? ListView(children: const [SizedBox(height: 160), Center(child: CircularProgressIndicator(color: AppColors.green700))])
                : _error != null && _files.isEmpty
                    ? ListView(children: [
                        const SizedBox(height: 160),
                        Center(
                            child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Text(_error!, style: const TextStyle(color: AppColors.filePdf)),
                          const SizedBox(height: 12),
                          ElevatedButton(onPressed: _load, child: const Text('Retry')),
                        ])),
                      ])
                    : _files.isEmpty
                        ? _emptyState()
                        : _fileListing(),
          ),
        ),
      ],
    );

    // Drag-and-drop upload — only where creating is allowed (your drive, or a
    // shared folder you can edit).
    if (!_canCreateHere) return body;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (d) async {
        setState(() => _dragging = false);
        final files = <({String path, String name})>[];
        for (final x in d.files) {
          if (await File(x.path).exists()) files.add((path: x.path, name: x.name));
        }
        if (files.isNotEmpty) await _uploadPaths(files);
      },
      child: Stack(children: [
        body,
        if (_dragging)
          Container(
            color: AppColors.greenActiveBg,
            child: const Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.cloud_upload, size: 64, color: AppColors.green700),
                SizedBox(height: 16),
                Text('Drop files here to upload', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.green800)),
              ]),
            ),
          ),
      ]),
    );
  }

  Widget _fileListing() {
    // Grid mode (files only): folders as cards, files as rows below.
    if (_isFiles && _isGrid) {
      final folders = _files.where((f) => f.isDirectory).toList();
      final files = _files.where((f) => !f.isDirectory).toList();
      return ListView(padding: const EdgeInsets.all(16), children: [
        if (folders.isNotEmpty) ...[
          const Text('FOLDERS', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.green700, letterSpacing: 0.5)),
          const SizedBox(height: 12),
          LayoutBuilder(builder: (context, c) {
            final w = c.maxWidth < 500 ? (c.maxWidth - 12) / 2 : 200.0;
            return Wrap(spacing: 12, runSpacing: 12, children: folders.map((f) => _folderCard(f, w)).toList());
          }),
          const SizedBox(height: 24),
        ],
        if (files.isNotEmpty) ...[
          const Text('FILES', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.green700, letterSpacing: 0.5)),
          const SizedBox(height: 8),
          ...files.map(_row),
        ],
      ]);
    }
    return ListView(padding: const EdgeInsets.all(16), children: _files.map(_row).toList());
  }

  Widget _folderCard(DriveFile f, double width) {
    final selected = _selected.contains(f.id);
    return GestureDetector(
      onLongPress: () => _toggleSelect(f.id),
      onSecondaryTapUp: (d) => _showContextMenu(d.globalPosition, f),
      child: InkWell(
        onTap: _selecting ? () => _toggleSelect(f.id) : () => _openFolder(f),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: width,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: selected ? AppColors.greenActiveBg : AppColors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: selected ? AppColors.green700 : AppColors.grey91),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.folder, size: 36, color: AppColors.green800),
              const Spacer(),
              if (_selecting)
                Icon(selected ? Icons.check_circle : Icons.radio_button_unchecked, size: 20, color: selected ? AppColors.green700 : AppColors.muted)
              else ...[
                _starButton(f),
                _menu(f),
              ],
            ]),
            const SizedBox(height: 8),
            Text(f.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.heading), maxLines: 1, overflow: TextOverflow.ellipsis),
          ]),
        ),
      ),
    );
  }

  Widget _selectionBar() {
    final sel = _selectedFiles;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: AppColors.greenActiveBg,
      child: Row(children: [
        Text('${sel.length} selected', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.heading)),
        const SizedBox(width: 12),
        TextButton(
          onPressed: sel.length == _files.length ? () => setState(() => _selected.clear()) : _selectAll,
          style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 0), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
          child: Text(sel.length == _files.length ? 'Clear all' : 'Select all', style: const TextStyle(fontSize: 12, color: AppColors.green700, fontWeight: FontWeight.w600)),
        ),
        const Spacer(),
        if (!_isTrash) IconButton(icon: const Icon(Icons.star_outline, size: 20, color: AppColors.heading), tooltip: 'Star', onPressed: _bulkStar, padding: EdgeInsets.zero, constraints: const BoxConstraints()),
        if (sel.any((f) => !f.isDirectory)) ...[
          const SizedBox(width: 12),
          IconButton(icon: const Icon(Icons.download, size: 20, color: AppColors.heading), tooltip: 'Download', onPressed: _bulkDownload, padding: EdgeInsets.zero, constraints: const BoxConstraints()),
        ],
        if (_isTrash) ...[
          const SizedBox(width: 12),
          IconButton(icon: const Icon(Icons.restore, size: 20, color: AppColors.green700), tooltip: 'Restore', onPressed: _bulkRestore, padding: EdgeInsets.zero, constraints: const BoxConstraints()),
          const SizedBox(width: 12),
          IconButton(icon: const Icon(Icons.delete_forever, size: 20, color: AppColors.filePdf), tooltip: 'Delete forever', onPressed: _bulkPurge, padding: EdgeInsets.zero, constraints: const BoxConstraints()),
        ] else ...[
          const SizedBox(width: 12),
          IconButton(icon: const Icon(Icons.delete_outline, size: 20, color: AppColors.filePdf), tooltip: 'Delete', onPressed: _bulkDelete, padding: EdgeInsets.zero, constraints: const BoxConstraints()),
        ],
        const SizedBox(width: 12),
        IconButton(icon: const Icon(Icons.close, size: 20, color: AppColors.muted), tooltip: 'Done', onPressed: _exitSelect, padding: EdgeInsets.zero, constraints: const BoxConstraints()),
      ]),
    );
  }

  Widget _uploadBanner() {
    final pct = _uploadTotal > 0 ? _uploadSent / _uploadTotal : null;
    String mb(int b) => (b / (1024 * 1024)).toStringAsFixed(1);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: AppColors.greenActiveBg,
      child: Row(children: [
        const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.green700)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Uploading $_uploadName${_uploadCount > 1 ? ' (${_uploadIndex + 1}/$_uploadCount)' : ''}',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppColors.heading), overflow: TextOverflow.ellipsis),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(value: pct, backgroundColor: AppColors.grey91, color: AppColors.green700, minHeight: 4),
            ),
            const SizedBox(height: 2),
            Text(_uploadTotal > 0 ? '${mb(_uploadSent)} / ${mb(_uploadTotal)} MB' : 'Starting…',
                style: const TextStyle(fontSize: 10, color: AppColors.muted)),
          ]),
        ),
        IconButton(
          icon: const Icon(Icons.close, size: 18, color: AppColors.filePdf),
          tooltip: 'Cancel',
          onPressed: () => setState(() => _uploadCancel = true),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
        ),
      ]),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Row(children: [
        Expanded(child: (_isFiles || _parentId != null) ? _breadcrumb() : Text(_title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.heading))),
        if (widget.mode == DriveViewMode.shared && _parentId == null) ...[
          _toggleChip('With me', !_showSharedByMe, () => setState(() { _showSharedByMe = false; _load(); })),
          const SizedBox(width: 6),
          _toggleChip('By me', _showSharedByMe, () => setState(() { _showSharedByMe = true; _load(); })),
        ],
        if (_isTrash && _files.isNotEmpty) ...[
          TextButton.icon(
            onPressed: _busy ? null : _emptyTrash,
            icon: const Icon(Icons.delete_sweep_outlined, size: 18, color: AppColors.filePdf),
            label: const Text('Empty Trash', style: TextStyle(color: AppColors.filePdf, fontSize: 13, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 4),
        ],
        // Multi-select toggle — lets you pick several files and run bulk actions
        // in any view (Files / Shared / Trash / Recent / Starred).
        if (_files.isNotEmpty)
          IconButton(
            icon: Icon(_selecting ? Icons.close : Icons.checklist_rounded, size: 20, color: _selecting ? AppColors.filePdf : AppColors.azure47),
            tooltip: _selecting ? 'Cancel selection' : 'Select',
            onPressed: _toggleSelectMode,
          ),
        // Sort menu
        PopupMenuButton<_SortCol>(
          icon: Icon(_sortAsc ? Icons.arrow_upward : Icons.arrow_downward, size: 18, color: AppColors.azure47),
          tooltip: 'Sort',
          onSelected: _setSort,
          itemBuilder: (_) => [
            _sortItem(_SortCol.name, 'Name'),
            _sortItem(_SortCol.date, 'Date modified'),
            _sortItem(_SortCol.size, 'Size'),
          ],
        ),
        if (_isFiles)
          // Grid/list toggle (Files mode only)
          Container(
            decoration: BoxDecoration(color: AppColors.grey96, borderRadius: BorderRadius.circular(6)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              _viewToggle(Icons.grid_view, _isGrid, () => setState(() => _isGrid = true)),
              _viewToggle(Icons.view_list, !_isGrid, () => setState(() => _isGrid = false)),
            ]),
          ),
        // Create actions — only where you're allowed to add files (hidden in a
        // view-only shared folder).
        if (_canCreateHere) ...[
          const SizedBox(width: 8),
          IconButton(icon: const Icon(Icons.upload_file, size: 20, color: AppColors.green800), tooltip: 'Upload', onPressed: _busy ? null : _upload),
          IconButton(icon: const Icon(Icons.create_new_folder_outlined, size: 20, color: AppColors.green800), tooltip: 'New folder', onPressed: _createFolder),
          IconButton(icon: const Icon(Icons.note_add_outlined, size: 20, color: AppColors.green800), tooltip: 'New file', onPressed: _createFile),
        ],
      ]),
    );
  }

  PopupMenuItem<_SortCol> _sortItem(_SortCol col, String label) => PopupMenuItem(
        value: col,
        child: Row(children: [
          Icon(_sortCol == col ? (_sortAsc ? Icons.arrow_upward : Icons.arrow_downward) : Icons.sort, size: 16, color: _sortCol == col ? AppColors.green800 : AppColors.body),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(color: _sortCol == col ? AppColors.green800 : null)),
        ]),
      );

  Widget _viewToggle(IconData icon, bool active, VoidCallback onTap) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(color: active ? AppColors.azure17 : Colors.transparent, borderRadius: BorderRadius.circular(4)),
          child: Icon(icon, size: 18, color: active ? AppColors.white : AppColors.body),
        ),
      );

  String get _title => switch (widget.mode) {
        DriveViewMode.files => 'My Files',
        DriveViewMode.recent => 'Recent',
        DriveViewMode.starred => 'Starred',
        DriveViewMode.shared => _showSharedByMe ? 'Shared by me' : 'Shared with me',
        DriveViewMode.trash => 'Trash',
      };

  Widget _toggleChip(String label, bool active, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(color: active ? AppColors.green700 : AppColors.grey96, borderRadius: BorderRadius.circular(20)),
          child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: active ? Colors.white : AppColors.body)),
        ),
      );

  Widget _breadcrumb() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        InkWell(
          onTap: _navigateToRoot,
          child: Text(_isFiles ? 'My Files' : _title, style: const TextStyle(fontSize: 14, color: AppColors.green700, fontWeight: FontWeight.w500)),
        ),
        ..._crumbs.asMap().entries.map((e) {
          final last = e.key == _crumbs.length - 1;
          return Row(mainAxisSize: MainAxisSize.min, children: [
            const Padding(padding: EdgeInsets.symmetric(horizontal: 6), child: Icon(Icons.chevron_right, size: 18, color: AppColors.muted)),
            InkWell(
              onTap: last ? null : () => _navigateToCrumb(e.key),
              child: Text(e.value.name,
                  style: TextStyle(fontSize: 14, color: last ? AppColors.heading : AppColors.green700, fontWeight: last ? FontWeight.w600 : FontWeight.w500)),
            ),
          ]);
        }),
      ]),
    );
  }

  Widget _emptyState() {
    final needsPhase2 = widget.mode != DriveViewMode.files && !_cache.isFullyLoaded;
    if (needsPhase2) {
      return ListView(children: const [
        SizedBox(height: 140),
        Center(child: CircularProgressIndicator(color: AppColors.green700, strokeWidth: 2)),
      ]);
    }
    final (icon, text) = switch (widget.mode) {
      DriveViewMode.trash => (Icons.delete_outline, 'Trash is empty'),
      DriveViewMode.starred => (Icons.star_outline, 'No starred files'),
      DriveViewMode.shared => (Icons.share_outlined, 'Nothing shared'),
      DriveViewMode.recent => (Icons.access_time, 'No recent files'),
      DriveViewMode.files => (Icons.folder_open, 'This folder is empty'),
    };
    return ListView(children: [
      const SizedBox(height: 100),
      Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 64, color: AppColors.muted),
        const SizedBox(height: 16),
        Text(text, style: const TextStyle(color: AppColors.body, fontSize: 16)),
        if (_canCreateHere) ...[
          const SizedBox(height: 16),
          ElevatedButton.icon(onPressed: _upload, icon: const Icon(Icons.upload_file), label: const Text('Upload File')),
        ],
      ])),
    ]);
  }

  Widget _starButton(DriveFile f) => IconButton(
        icon: Icon(f.isStarred ? Icons.star : Icons.star_border, size: 20, color: f.isStarred ? AppColors.fileSketch : AppColors.muted),
        tooltip: f.isStarred ? 'Unstar' : 'Star',
        onPressed: () => _toggleStar(f),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        visualDensity: VisualDensity.compact,
      );

  Widget _row(DriveFile f) {
    final selected = _selected.contains(f.id);
    return GestureDetector(
      onLongPress: () => _toggleSelect(f.id),
      onSecondaryTapUp: (d) => _showContextMenu(d.globalPosition, f),
      child: InkWell(
        onTap: _selecting
            ? () => _toggleSelect(f.id)
            : (_isTrash ? null : () => _open(f)),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          decoration: BoxDecoration(
            color: selected ? AppColors.greenActiveBg : null,
            border: const Border(bottom: BorderSide(color: AppColors.grey91, width: 0.5)),
          ),
          child: Row(children: [
            if (_selecting) ...[
              Icon(selected ? Icons.check_circle : Icons.radio_button_unchecked, size: 22, color: selected ? AppColors.green700 : AppColors.muted),
              const SizedBox(width: 10),
            ],
            FileIcon(extension: f.extension, isDirectory: f.isDirectory, size: 32),
            const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(child: Text(f.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: AppColors.heading), overflow: TextOverflow.ellipsis)),
              ]),
              Text(
                _isTrash && f.deletedAt != null
                    ? 'Deleted ${DateFormat('MMM d, y').format(f.deletedAt!.toLocal())}'
                    : f.isDirectory
                        ? (f.updatedAt != null ? DateFormat('MMM d, y').format(f.updatedAt!.toLocal()) : '')
                        : '${f.sizeFormatted}${f.updatedAt != null ? '  ·  ${DateFormat('MMM d, y').format(f.updatedAt!.toLocal())}' : ''}',
                style: const TextStyle(fontSize: 11, color: AppColors.muted),
                ),
              ]),
            ),
            if (!_selecting) ...[
              if (!_isTrash) _starButton(f),
              _menu(f),
            ],
          ]),
        ),
      ),
    );
  }

  void _onMenuAction(String v, DriveFile f) {
    switch (v) {
      case 'open': _open(f);
      case 'download': _download(f);
      case 'share': _share(f);
      case 'rename': _rename(f);
      case 'move': _move(f);
      case 'copy': _copy(f);
      case 'star': _toggleStar(f);
      case 'versions': _versions(f);
      case 'comments': _comments(f);
      case 'activity': _activity(f);
      case 'expiration': _expiration(f);
      case 'delete': _delete(f);
      case 'restore': _restore(f);
      case 'purge': _purge(f);
    }
  }

  List<PopupMenuEntry<String>> _menuItems(DriveFile f) => _isTrash
      ? const [
          PopupMenuItem(value: 'restore', child: Row(children: [Icon(Icons.restore, size: 16, color: AppColors.green700), SizedBox(width: 8), Text('Restore')])),
          PopupMenuItem(value: 'purge', child: Row(children: [Icon(Icons.delete_forever, size: 16, color: AppColors.filePdf), SizedBox(width: 8), Text('Delete forever', style: TextStyle(color: AppColors.filePdf))])),
        ]
      : [
          if (!f.isDirectory) const PopupMenuItem(value: 'open', child: Row(children: [Icon(Icons.open_in_new, size: 16, color: AppColors.body), SizedBox(width: 8), Text('Open')])),
          if (!f.isDirectory) const PopupMenuItem(value: 'download', child: Row(children: [Icon(Icons.download, size: 16, color: AppColors.body), SizedBox(width: 8), Text('Download')])),
          if (_canManage(f)) const PopupMenuItem(value: 'share', child: Row(children: [Icon(Icons.share, size: 16, color: AppColors.body), SizedBox(width: 8), Text('Share')])),
          PopupMenuItem(value: 'star', child: Row(children: [Icon(f.isStarred ? Icons.star : Icons.star_outline, size: 16, color: f.isStarred ? AppColors.fileSketch : AppColors.body), const SizedBox(width: 8), Text(f.isStarred ? 'Unstar' : 'Star')])),
          if (_canWrite(f)) const PopupMenuItem(value: 'rename', child: Row(children: [Icon(Icons.edit, size: 16, color: AppColors.body), SizedBox(width: 8), Text('Rename')])),
          if (_canWrite(f)) const PopupMenuItem(value: 'move', child: Row(children: [Icon(Icons.drive_file_move_outline, size: 16, color: AppColors.body), SizedBox(width: 8), Text('Move to…')])),
          if (!f.isDirectory) const PopupMenuItem(value: 'copy', child: Row(children: [Icon(Icons.copy_all_outlined, size: 16, color: AppColors.body), SizedBox(width: 8), Text('Make a copy')])),
          const PopupMenuDivider(),
          if (!f.isDirectory) const PopupMenuItem(value: 'versions', child: Row(children: [Icon(Icons.history, size: 16, color: AppColors.body), SizedBox(width: 8), Text('Version history')])),
          const PopupMenuItem(value: 'comments', child: Row(children: [Icon(Icons.comment_outlined, size: 16, color: AppColors.body), SizedBox(width: 8), Text('Comments')])),
          const PopupMenuItem(value: 'activity', child: Row(children: [Icon(Icons.history_toggle_off, size: 16, color: AppColors.body), SizedBox(width: 8), Text('Activity')])),
          if (_canManage(f)) const PopupMenuItem(value: 'expiration', child: Row(children: [Icon(Icons.event_busy, size: 16, color: AppColors.body), SizedBox(width: 8), Text('Set expiration…')])),
          if (_canWrite(f)) const PopupMenuDivider(),
          if (_canWrite(f)) const PopupMenuItem(value: 'delete', child: Row(children: [Icon(Icons.delete_outline, size: 16, color: AppColors.filePdf), SizedBox(width: 8), Text('Delete', style: TextStyle(color: AppColors.filePdf))])),
        ];

  Widget _menu(DriveFile f) => PopupMenuButton<String>(
        icon: const Icon(Icons.more_horiz, color: AppColors.muted),
        onSelected: (v) => _onMenuAction(v, f),
        itemBuilder: (_) => _menuItems(f),
      );

  /// Show the same menu at a right-click / long-press position.
  Future<void> _showContextMenu(Offset globalPos, DriveFile f) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(globalPos & const Size(1, 1), Offset.zero & overlay.size),
      items: _menuItems(f),
    );
    if (v != null) _onMenuAction(v, f);
  }
}

/// Folder picker for Move — navigates the drive tree and returns the chosen
/// destination ('root' for the drive root, or a folder uuid), null on cancel.
class _MovePicker extends StatefulWidget {
  final DriveApi api;
  final String movingId; // exclude the item being moved
  final String fileName;
  const _MovePicker({required this.api, required this.movingId, required this.fileName});

  @override
  State<_MovePicker> createState() => _MovePickerState();
}

class _MovePickerState extends State<_MovePicker> {
  String? _parentId; // null → root
  String _label = 'My Files';
  final List<({String? id, String name})> _stack = [];
  List<DriveFile> _folders = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final items = await widget.api.listFiles(parentId: _parentId);
      _folders = items.where((f) => f.isDirectory && f.id != widget.movingId).toList();
    } catch (_) {
      _folders = [];
    }
    if (mounted) setState(() => _loading = false);
  }

  void _enter(DriveFile f) {
    _stack.add((id: _parentId, name: _label));
    setState(() { _parentId = f.id; _label = f.name; });
    _load();
  }

  void _up() {
    if (_stack.isEmpty) return;
    final prev = _stack.removeLast();
    setState(() { _parentId = prev.id; _label = prev.name; });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Move "${widget.fileName}"', overflow: TextOverflow.ellipsis),
      content: SizedBox(
        width: 400,
        height: 380,
        child: Column(children: [
          Row(children: [
            if (_stack.isNotEmpty)
              IconButton(icon: const Icon(Icons.arrow_back, size: 20), onPressed: _up, padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 32, minHeight: 32)),
            const Icon(Icons.folder_open, size: 18, color: AppColors.green800),
            const SizedBox(width: 8),
            Expanded(child: Text(_label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.heading), overflow: TextOverflow.ellipsis)),
          ]),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: AppColors.green700, strokeWidth: 2))
                : _folders.isEmpty
                    ? const Center(child: Text('No subfolders', style: TextStyle(color: AppColors.muted, fontSize: 13)))
                    : ListView(children: _folders.map((f) => ListTile(
                          dense: true,
                          leading: const Icon(Icons.folder, size: 20, color: AppColors.green800),
                          title: Text(f.name, style: const TextStyle(fontSize: 13)),
                          trailing: const Icon(Icons.chevron_right, size: 18, color: AppColors.muted),
                          onTap: () => _enter(f),
                        )).toList()),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ElevatedButton.icon(
          onPressed: () => Navigator.pop(context, _parentId ?? 'root'),
          icon: const Icon(Icons.check, size: 18),
          label: Text('Move here'),
          style: ElevatedButton.styleFrom(backgroundColor: AppColors.green800, foregroundColor: AppColors.white),
        ),
      ],
    );
  }
}
