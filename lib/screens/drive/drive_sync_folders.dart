// drive_sync_folders.dart — choose which Drive folders sync to this device.
//
// A folder tree (loaded as you expand it) with a checkbox per folder: checked
// folders sync, unchecked ones (and everything inside) don't. Files at the top
// of the sync root always sync. Unchecking never deletes anything: copies
// already on this device stay until you remove them, and the Drive is untouched.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/theme.dart';
import '../../models/drive_file.dart';
import '../../services/drive/drive_account_manager.dart';
import '../../services/drive/drive_api.dart';
import '../../services/drive/drive_client.dart';
import '../../services/drive/drive_sync_service.dart';

class DriveSyncFolders extends StatefulWidget {
  /// Injected in tests; otherwise the active account's API.
  final DriveApi? api;
  const DriveSyncFolders({super.key, this.api});

  @override
  State<DriveSyncFolders> createState() => _DriveSyncFoldersState();
}

class _Node {
  final DriveFile folder;
  final String rel; // path under the sync root, '/' separators
  final int depth;
  List<_Node>? children; // null = not loaded yet
  bool expanded = false;
  bool loading = false;
  _Node(this.folder, this.rel, this.depth);
}

class _DriveSyncFoldersState extends State<DriveSyncFolders> {
  late Set<String> _excluded;
  List<_Node>? _roots;
  String? _error;
  bool _saving = false;
  late final Set<String> _initial;

  DriveApi get _api => widget.api ?? context.read<DriveAccountManager>().activeApi!;
  DriveSyncService get _sync => context.read<DriveSyncService>();

  @override
  void initState() {
    super.initState();
    _initial = {..._sync.excludedFolders};
    _excluded = {..._initial};
    _loadRoots();
  }

  Future<List<_Node>> _children(String? parentId, String prefix, int depth) async {
    final items = await _api.listFiles(parentId: parentId, limit: 1000);
    final folders = items.where((f) => f.isDirectory && !f.name.startsWith('.')).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return [for (final f in folders) _Node(f, prefix.isEmpty ? f.name : '$prefix/${f.name}', depth)];
  }

  Future<void> _loadRoots() async {
    setState(() => _error = null);
    try {
      final roots = await _children(_sync.remoteParentId, '', 0);
      if (mounted) setState(() => _roots = roots);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    }
  }

  Future<void> _toggleExpand(_Node n) async {
    if (n.expanded) return setState(() => n.expanded = false);
    if (n.children == null) {
      setState(() => n.loading = true);
      try {
        n.children = await _children(n.folder.id, n.rel, n.depth + 1);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(friendlyError(e)), backgroundColor: AppColors.filePdf));
        }
      }
      n.loading = false;
    }
    if (mounted) setState(() => n.expanded = n.children != null);
  }

  /// true = syncs, false = not synced, null = syncs but something inside doesn't.
  bool? _value(_Node n) {
    if (isExcludedPath(n.rel, _excluded)) return false;
    return _excluded.any((e) => e.startsWith('${n.rel}/')) ? null : true;
  }

  /// Unsynced because a folder ABOVE it is unsynced (its box can't change).
  bool _lockedByParent(_Node n) {
    final parts = n.rel.split('/');
    for (var i = 1; i < parts.length; i++) {
      if (_excluded.contains(parts.sublist(0, i).join('/'))) return true;
    }
    return false;
  }

  void _toggle(_Node n) {
    setState(() {
      if (_excluded.contains(n.rel)) {
        _excluded.remove(n.rel);
      } else {
        _excluded
          ..removeWhere((e) => e.startsWith('${n.rel}/')) // covered by this one now
          ..add(n.rel);
      }
    });
  }

  bool get _changed => _excluded.length != _initial.length || !_excluded.containsAll(_initial);

  Future<void> _save() async {
    setState(() => _saving = true);
    await _sync.setExcludedFolders(_excluded);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Saved. Folder sync follows your choice from the next sync.'),
      backgroundColor: AppColors.green700,
    ));
    Navigator.of(context).pop();
  }

  List<_Node> _visible() {
    final out = <_Node>[];
    void add(List<_Node> nodes) {
      for (final n in nodes) {
        out.add(n);
        if (n.expanded && n.children != null) add(n.children!);
      }
    }

    add(_roots ?? const []);
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final rows = _visible();
    return Scaffold(
      backgroundColor: AppColors.grey98,
      appBar: AppBar(
        title: const Text('Folders to sync', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        backgroundColor: AppColors.white,
        foregroundColor: AppColors.heading,
        elevation: 0,
        actions: [
          TextButton(
            onPressed: _changed && !_saving ? _save : null,
            child: const Text('Save', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: double.infinity,
          color: AppColors.white,
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: const Text(
            'Checked folders sync to this device. Unchecking a folder stops syncing it: '
            'copies already here stay until you delete them, and nothing is deleted from your Drive. '
            'Files that aren’t in a folder always sync.',
            style: TextStyle(fontSize: 12, color: AppColors.body),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _error != null
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.body)),
                    TextButton(onPressed: _loadRoots, child: const Text('Try again')),
                  ]),
                )
              : _roots == null
                  ? const Center(child: CircularProgressIndicator(color: AppColors.green700, strokeWidth: 2))
                  : rows.isEmpty
                      ? const Center(
                          child: Text('There are no folders to choose from.', style: TextStyle(color: AppColors.body)))
                      : ListView.builder(
                          itemCount: rows.length,
                          itemBuilder: (_, i) => _row(rows[i]),
                        ),
        ),
      ]),
    );
  }

  Widget _row(_Node n) {
    final locked = _lockedByParent(n);
    final expandable = n.children == null || n.children!.isNotEmpty;
    return Material(
      color: AppColors.white,
      child: InkWell(
        onTap: expandable ? () => _toggleExpand(n) : null,
        child: Padding(
          padding: EdgeInsets.only(left: 8.0 + n.depth * 20, right: 8),
          child: Row(children: [
            SizedBox(
              width: 32,
              child: n.loading
                  ? const Padding(
                      padding: EdgeInsets.all(8),
                      child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
                  : expandable
                      ? Icon(n.expanded ? Icons.expand_more : Icons.chevron_right, color: AppColors.muted)
                      : null,
            ),
            Checkbox(
              tristate: true,
              value: _value(n),
              activeColor: AppColors.green700,
              onChanged: locked ? null : (_) => _toggle(n),
            ),
            const Icon(Icons.folder, color: AppColors.green800, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(n.folder.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, color: locked ? AppColors.muted : AppColors.heading)),
            ),
          ]),
        ),
      ),
    );
  }
}
