// drive_tags_screen.dart — the user's tags; tapping one lists every file that
// carries it (across all folders), like the web's tag filter.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/theme.dart';
import '../../services/drive/drive_account_manager.dart';
import '../../services/drive/drive_api.dart';
import '../../services/drive/drive_client.dart';
import 'drive_file_actions.dart' show driveTagColor;
import 'drive_files_screen.dart';

class DriveTagsScreen extends StatefulWidget {
  final DriveApi? api; // injected in tests
  const DriveTagsScreen({super.key, this.api});

  @override
  State<DriveTagsScreen> createState() => _DriveTagsScreenState();
}

class _DriveTagsScreenState extends State<DriveTagsScreen> {
  List<DriveTag>? _tags;
  String? _error;
  DriveTag? _open; // the tag whose files are shown

  DriveApi get _api => widget.api ?? context.read<DriveAccountManager>().activeApi!;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final t = await _api.listTags();
      t.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      if (mounted) setState(() => _tags = t);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final open = _open;
    if (open != null) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 20, 0),
          child: TextButton.icon(
            onPressed: () => setState(() => _open = null),
            icon: const Icon(Icons.arrow_back, size: 18),
            label: const Text('All tags'),
          ),
        ),
        Expanded(child: DriveFilesScreen(key: ValueKey('tag-${open.id}'), mode: DriveViewMode.tag, tag: open)),
      ]);
    }
    final tags = _tags;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
        child: Row(children: [
          const Expanded(child: Text('Tags', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.heading))),
          IconButton(tooltip: 'Refresh', onPressed: _load, icon: const Icon(Icons.refresh, color: AppColors.azure47)),
        ]),
      ),
      const Divider(height: 1),
      Expanded(
        child: _error != null
            ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(_error!, style: const TextStyle(color: AppColors.body)),
                TextButton(onPressed: _load, child: const Text('Try again')),
              ]))
            : tags == null
                ? const Center(child: CircularProgressIndicator(color: AppColors.green700, strokeWidth: 2))
                : tags.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(32),
                          child: Text('No tags yet. Add one from a file’s menu → Tags…',
                              textAlign: TextAlign.center, style: TextStyle(color: AppColors.muted)),
                        ),
                      )
                    : ListView.separated(
                        itemCount: tags.length,
                        separatorBuilder: (_, __) => const Divider(height: 1, indent: 56),
                        itemBuilder: (_, i) => ListTile(
                          leading: CircleAvatar(radius: 8, backgroundColor: driveTagColor(tags[i].color)),
                          title: Text(tags[i].name),
                          trailing: const Icon(Icons.chevron_right, color: AppColors.muted),
                          onTap: () => setState(() => _open = tags[i]),
                        ),
                      ),
      ),
    ]);
  }
}
