import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../config/theme.dart';
import '../services/sync_service.dart';
import '../services/webdav_service.dart';
import '../services/auth_service.dart';
import '../models/nc_file.dart';

class SyncConfigScreen extends StatefulWidget {
  const SyncConfigScreen({super.key});

  @override
  State<SyncConfigScreen> createState() => _SyncConfigScreenState();
}

class _SyncConfigScreenState extends State<SyncConfigScreen> {
  late TextEditingController _fileSizeLimitCtrl;
  Set<String> _selectedFolders = {};
  late SyncDirection _syncDirection;
  late Set<String> _excludedPaths;
  late Set<String> _excludedLocalPaths;

  @override
  void initState() {
    super.initState();
    final sync = context.read<SyncService>();
    final limitMb = sync.maxFileSizeBytes / (1024 * 1024);
    _fileSizeLimitCtrl = TextEditingController(
      text: limitMb > 0 ? limitMb.toStringAsFixed(1) : '0',
    );
    _syncDirection = sync.syncDirection;
    _selectedFolders = Set.from(sync.includedFolders);
    _excludedPaths = Set.from(sync.excludedPaths);
    _excludedLocalPaths = Set.from(sync.excludedLocalPaths);
  }

  @override
  void dispose() {
    _fileSizeLimitCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final sync = context.read<SyncService>();

    // Sync direction
    await sync.setSyncDirection(_syncDirection);

    // File size limit
    final limitMb = double.tryParse(_fileSizeLimitCtrl.text) ?? 0;
    final limitBytes = (limitMb * 1024 * 1024).round();
    await sync.setMaxFileSizeBytes(limitBytes);

    // Included folders
    await sync.setIncludedFolders(_selectedFolders);

    // Excluded server paths
    for (final path in sync.excludedPaths) {
      if (!_excludedPaths.contains(path)) await sync.removeExcludedPath(path);
    }
    for (final path in _excludedPaths) {
      if (!sync.excludedPaths.contains(path)) await sync.addExcludedPath(path);
    }

    // Excluded local paths
    for (final path in sync.excludedLocalPaths) {
      if (!_excludedLocalPaths.contains(path)) await sync.removeExcludedLocalPath(path);
    }
    for (final path in _excludedLocalPaths) {
      if (!sync.excludedLocalPaths.contains(path)) await sync.addExcludedLocalPath(path);
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Sync configuration saved'),
          backgroundColor: AppColors.green700,
        ),
      );
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 600;

    return Scaffold(
      backgroundColor: AppColors.grey98,
      appBar: AppBar(
        title: const Text('Sync Configuration'),
        backgroundColor: AppColors.white,
        foregroundColor: AppColors.heading,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      body: ListView(
        padding: EdgeInsets.symmetric(
          horizontal: isMobile ? 12 : 24,
          vertical: isMobile ? 16 : 24,
        ),
        children: [
          // ---- Sync Direction ----
          _buildSectionCard(
            title: 'Sync Direction',
            icon: Icons.swap_vert,
            children: [
              const Text(
                'Choose which direction files should sync.',
                style: TextStyle(fontSize: 13, color: AppColors.body),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: AppColors.grey96,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<SyncDirection>(
                    value: _syncDirection,
                    isExpanded: true,
                    items: const [
                      DropdownMenuItem(
                        value: SyncDirection.twoWay,
                        child: Text('Two-way sync'),
                      ),
                      DropdownMenuItem(
                        value: SyncDirection.downloadOnly,
                        child: Text('Download only'),
                      ),
                      DropdownMenuItem(
                        value: SyncDirection.uploadOnly,
                        child: Text('Upload only'),
                      ),
                    ],
                    onChanged: (v) {
                      if (v != null) setState(() => _syncDirection = v);
                    },
                    style: const TextStyle(
                        fontSize: 14, color: AppColors.heading),
                    dropdownColor: AppColors.white,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // ---- File Size Limit ----
          _buildSectionCard(
            title: 'File Size Limit',
            icon: Icons.straighten,
            children: [
              const Text(
                'Skip files larger than this size. Set to 0 for no limit.',
                style: TextStyle(fontSize: 13, color: AppColors.body),
              ),
              const SizedBox(height: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Max File Size (MB)',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: AppColors.body,
                    ),
                  ),
                  const SizedBox(height: 4),
                  TextField(
                    controller: _fileSizeLimitCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[\d.]')),
                    ],
                    decoration: InputDecoration(
                      hintText: '0 = no limit',
                      filled: true,
                      fillColor: AppColors.grey96,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                    style: const TextStyle(
                        fontSize: 14, color: AppColors.heading),
                  ),
                ],
              ),
            ],
          ),

          const SizedBox(height: 16),

          // ---- Selective Sync (Folder Tree) ----
          _buildSectionCard(
            title: 'Selective Sync',
            icon: Icons.folder_special,
            children: [
              const Text(
                'Choose which server folders to sync. '
                'Expand folders to select subfolders. '
                'Leave all unchecked to sync everything.',
                style: TextStyle(fontSize: 13, color: AppColors.body),
              ),
              const SizedBox(height: 12),
              Container(
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.grey91),
                  borderRadius: BorderRadius.circular(8),
                ),
                constraints: const BoxConstraints(maxHeight: 400),
                child: _FolderTree(
                  webdav: WebDavService(context.read<AuthService>()),
                  selectedFolders: _selectedFolders,
                  onSelectionChanged: (selected) {
                    setState(() => _selectedFolders = selected);
                  },
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // ---- Excluded Server Paths (Download) ----
          _buildSectionCard(
            title: 'Exclude from Server (Downloads)',
            icon: Icons.cloud_off,
            children: [
              const Text('Server files/folders to skip when downloading.', style: TextStyle(fontSize: 13, color: AppColors.body)),
              const SizedBox(height: 12),
              ..._buildExcludeList(_excludedPaths, (path) => setState(() => _excludedPaths.remove(path))),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => _pickServerExclusion(),
                icon: const Icon(Icons.cloud, size: 18),
                label: const Text('Browse Server'),
                style: OutlinedButton.styleFrom(foregroundColor: AppColors.green800, side: const BorderSide(color: AppColors.green800), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // ---- Excluded Local Paths (Upload) ----
          _buildSectionCard(
            title: 'Exclude from Local (Uploads)',
            icon: Icons.folder_off,
            children: [
              const Text('Local files/folders to skip when uploading.', style: TextStyle(fontSize: 13, color: AppColors.body)),
              const SizedBox(height: 12),
              ..._buildExcludeList(_excludedLocalPaths, (path) => setState(() => _excludedLocalPaths.remove(path))),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => _pickLocalExclusion(),
                icon: const Icon(Icons.folder, size: 18),
                label: const Text('Browse Local'),
                style: OutlinedButton.styleFrom(foregroundColor: AppColors.green800, side: const BorderSide(color: AppColors.green800), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
              ),
            ],
          ),

          const SizedBox(height: 24),

          // ---- Save Button ----
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _save,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.green800,
                foregroundColor: AppColors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: const Text(
                'Save',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
          ),

          const SizedBox(height: 24),
        ],
      ),
    );
  }

  List<Widget> _buildExcludeList(Set<String> paths, void Function(String) onRemove) {
    if (paths.isEmpty) {
      return [const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('None', style: TextStyle(fontSize: 13, color: AppColors.muted)))];
    }
    return (paths.toList()..sort()).map((path) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(color: AppColors.grey96, borderRadius: BorderRadius.circular(6)),
              child: Text(path.split('/').last.isNotEmpty ? path.split('/').last : path, style: const TextStyle(fontSize: 13, color: AppColors.heading)),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.close, size: 18, color: AppColors.filePdf),
            onPressed: () => onRemove(path),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ],
      ),
    )).toList();
  }

  Future<void> _pickServerExclusion() async {
    // Show server folder browser
    final auth = context.read<AuthService>();
    final webdav = WebDavService(auth);

    try {
      final selected = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Select server file/folder to exclude'),
          content: SizedBox(
            width: 400,
            height: 400,
            child: _ServerBrowser(webdav: webdav),
          ),
        ),
      );

      if (selected != null && selected.isNotEmpty) {
        setState(() => _excludedPaths.add(selected));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
  }

  Future<void> _pickLocalExclusion() async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Exclude from local'),
        content: const Text('What do you want to exclude?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(ctx, 'folder'),
            icon: const Icon(Icons.folder, size: 18),
            label: const Text('Folder'),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(ctx, 'file'),
            icon: const Icon(Icons.insert_drive_file, size: 18),
            label: const Text('File'),
          ),
        ],
      ),
    );
    if (choice == null) return;

    if (choice == 'folder') {
      final result = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Choose local folder to exclude',
      );
      if (result != null) setState(() => _excludedLocalPaths.add(result));
    } else {
      final result = await FilePicker.platform.pickFiles(dialogTitle: 'Choose local file to exclude');
      if (result != null && result.files.isNotEmpty && result.files.first.path != null) {
        setState(() => _excludedLocalPaths.add(result.files.first.path!));
      }
    }
  }

  Widget _buildSectionCard({
    required String title,
    required IconData icon,
    required List<Widget> children,
  }) {
    final isMobile = MediaQuery.of(context).size.width < 600;
    return Card(
      color: AppColors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.grey91, width: 1),
      ),
      child: Padding(
        padding: EdgeInsets.all(isMobile ? 14 : 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: AppColors.green800),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppColors.heading,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Divider(height: 1, color: AppColors.grey91),
            const SizedBox(height: 16),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// Expandable folder tree for selective sync — loads subfolders on demand.
class _FolderTree extends StatefulWidget {
  final WebDavService webdav;
  final Set<String> selectedFolders;
  final ValueChanged<Set<String>> onSelectionChanged;

  const _FolderTree({
    required this.webdav,
    required this.selectedFolders,
    required this.onSelectionChanged,
  });

  @override
  State<_FolderTree> createState() => _FolderTreeState();
}

class _FolderTreeState extends State<_FolderTree> {
  // path → list of child folders (loaded on demand)
  final Map<String, List<NcFile>> _children = {};
  final Set<String> _expanded = {};
  final Set<String> _loading = {};
  bool _rootLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadChildren('/');
  }

  Future<void> _loadChildren(String path) async {
    if (_children.containsKey(path)) return;
    setState(() => path == '/' ? _rootLoading = true : _loading.add(path));
    try {
      final items = await widget.webdav.listFiles(path);
      final folders = items.where((f) => f.isDirectory).toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      if (mounted) {
        setState(() {
          _children[path] = folders;
          if (path == '/') _rootLoading = false;
          _loading.remove(path);
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          if (path == '/') {
            _rootLoading = false;
            _error = e.toString();
          }
          _loading.remove(path);
        });
      }
    }
  }

  void _toggle(String path) {
    final selected = Set<String>.from(widget.selectedFolders);
    if (selected.contains(path)) {
      // Uncheck this + all children
      selected.removeWhere((p) => p == path || p.startsWith(path));
    } else {
      selected.add(path);
    }
    widget.onSelectionChanged(selected);
  }

  bool _isSelected(String path) => widget.selectedFolders.contains(path);

  /// True if a parent of this path is selected (inherited selection).
  bool _isParentSelected(String path) {
    for (final sel in widget.selectedFolders) {
      if (path != sel && path.startsWith(sel)) return true;
    }
    return false;
  }

  /// True if some children of this path are selected but not all.
  bool _isPartiallySelected(String path) {
    if (_isSelected(path)) return false;
    return widget.selectedFolders.any((p) => p.startsWith(path) && p != path);
  }

  @override
  Widget build(BuildContext context) {
    if (_rootLoading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: CircularProgressIndicator(color: AppColors.green800, strokeWidth: 2),
        ),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Could not load folders: $_error', style: const TextStyle(fontSize: 13, color: AppColors.filePdf)),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () {
                _error = null;
                _children.remove('/');
                _loadChildren('/');
              },
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }
    final rootFolders = _children['/'] ?? [];
    if (rootFolders.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('No folders found on server.', style: TextStyle(fontSize: 13, color: AppColors.muted)),
      );
    }
    return ListView(
      shrinkWrap: true,
      children: rootFolders.expand((f) => _buildNode(f, 0)).toList(),
    );
  }

  List<Widget> _buildNode(NcFile folder, int depth) {
    final isExp = _expanded.contains(folder.path);
    final isLoad = _loading.contains(folder.path);
    final selected = _isSelected(folder.path);
    final parentSelected = _isParentSelected(folder.path);
    final partial = _isPartiallySelected(folder.path);

    final widgets = <Widget>[
      InkWell(
        onTap: () {
          if (isExp) {
            setState(() => _expanded.remove(folder.path));
          } else {
            setState(() => _expanded.add(folder.path));
            _loadChildren(folder.path);
          }
        },
        child: Padding(
          padding: EdgeInsets.only(left: 8.0 + depth * 24, top: 6, bottom: 6, right: 8),
          child: Row(
            children: [
              // Expand/collapse arrow
              SizedBox(
                width: 24,
                child: isLoad
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.green700))
                    : Icon(
                        isExp ? Icons.expand_more : Icons.chevron_right,
                        size: 20,
                        color: AppColors.muted,
                      ),
              ),
              // Checkbox
              SizedBox(
                width: 28,
                child: Checkbox(
                  value: selected || parentSelected ? true : partial ? null : false,
                  tristate: true,
                  onChanged: (_) => _toggle(folder.path),
                  activeColor: AppColors.green800,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.folder, size: 18, color: selected || parentSelected ? AppColors.green800 : AppColors.muted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  folder.name,
                  style: TextStyle(
                    fontSize: 13,
                    color: parentSelected ? AppColors.muted : AppColors.heading,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    ];

    // Show children if expanded
    if (isExp && _children.containsKey(folder.path)) {
      for (final child in _children[folder.path]!) {
        widgets.addAll(_buildNode(child, depth + 1));
      }
      if (_children[folder.path]!.isEmpty && !isLoad) {
        widgets.add(Padding(
          padding: EdgeInsets.only(left: 32.0 + (depth + 1) * 24, top: 4, bottom: 4),
          child: const Text('No subfolders', style: TextStyle(fontSize: 12, color: AppColors.muted, fontStyle: FontStyle.italic)),
        ));
      }
    }

    return widgets;
  }
}

/// Navigable server browser for excluding specific paths.
class _ServerBrowser extends StatefulWidget {
  final WebDavService webdav;
  const _ServerBrowser({required this.webdav});

  @override
  State<_ServerBrowser> createState() => _ServerBrowserState();
}

class _ServerBrowserState extends State<_ServerBrowser> {
  String _path = '/';
  List<NcFile> _files = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      _files = await widget.webdav.listFiles(_path);
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            if (_path != '/')
              IconButton(
                icon: const Icon(Icons.arrow_back, size: 20),
                onPressed: () {
                  final parts = _path.split('/').where((p) => p.isNotEmpty).toList();
                  parts.removeLast();
                  _path = parts.isEmpty ? '/' : '/${parts.join('/')}';
                  _load();
                },
              ),
            Expanded(
              child: Text(_path, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500), overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
        const Divider(),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : ListView.builder(
                  itemCount: _files.length,
                  itemBuilder: (ctx, i) {
                    final f = _files[i];
                    return ListTile(
                      dense: true,
                      leading: Icon(f.isDirectory ? Icons.folder : Icons.insert_drive_file, size: 20, color: f.isDirectory ? AppColors.green800 : AppColors.body),
                      title: Text(f.name, style: const TextStyle(fontSize: 13)),
                      trailing: TextButton(
                        onPressed: () => Navigator.pop(context, f.path),
                        child: const Text('Exclude', style: TextStyle(color: AppColors.filePdf, fontSize: 12)),
                      ),
                      onTap: f.isDirectory ? () { _path = f.path; _load(); } : null,
                    );
                  },
                ),
        ),
      ],
    );
  }
}
