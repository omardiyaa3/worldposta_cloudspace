// drive_file_sheets.dart — reusable per-file panels (version history, comments,
// activity, expiration) opened from the files-screen menu AND the preview.

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../config/theme.dart';
import '../../models/drive_file.dart';
import '../../services/drive/drive_account_manager.dart';
import '../../services/drive/drive_api.dart';
import '../../services/drive/drive_client.dart';

DriveApi _api(BuildContext c) => c.read<DriveAccountManager>().activeApi!;

String _ago(DateTime? d) {
  if (d == null) return '';
  final diff = DateTime.now().difference(d);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  return DateFormat('MMM d, y').format(d.toLocal());
}

void _snack(BuildContext c, String m, {bool err = false}) {
  ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m), backgroundColor: err ? AppColors.filePdf : AppColors.green700));
}

// ── Version history ─────────────────────────────────────────────────────────

/// [onRestored] lets the preview reload its content after a restore.
void showDriveVersionsSheet(BuildContext context, DriveFile file, {VoidCallback? onRestored}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (_) => _VersionsSheet(file: file, onRestored: onRestored),
  );
}

class _VersionsSheet extends StatefulWidget {
  final DriveFile file;
  final VoidCallback? onRestored;
  const _VersionsSheet({required this.file, this.onRestored});
  @override
  State<_VersionsSheet> createState() => _VersionsSheetState();
}

class _VersionsSheetState extends State<_VersionsSheet> {
  late Future<List<DriveVersion>> _future;
  @override
  void initState() {
    super.initState();
    _future = _api(context).listVersions(widget.file.id);
  }

  @override
  Widget build(BuildContext context) {
    return _panel(context, Icons.history, 'Version history', FutureBuilder<List<DriveVersion>>(
      future: _future,
      builder: (ctx, snap) => snap.connectionState == ConnectionState.waiting
          ? const Center(child: CircularProgressIndicator(color: AppColors.green700))
          : (snap.data?.isEmpty ?? true)
              ? const Center(child: Text('No versions', style: TextStyle(color: AppColors.muted)))
              : ListView(children: snap.data!.map((v) => ListTile(
                    dense: true,
                    leading: Icon(v.isCurrent ? Icons.check_circle : Icons.history, size: 20, color: v.isCurrent ? AppColors.green700 : AppColors.muted),
                    title: Text(v.label ?? (v.createdAt != null ? DateFormat('MMM d, y  h:mm a').format(v.createdAt!.toLocal()) : v.id.substring(0, 8)), style: const TextStyle(fontSize: 13)),
                    subtitle: Text('${(v.sizeBytes / 1024).toStringAsFixed(1)} KB${v.isCurrent ? ' · current' : ''}', style: const TextStyle(fontSize: 11, color: AppColors.muted)),
                    trailing: v.isCurrent
                        ? null
                        : TextButton(
                            onPressed: () async {
                              final nav = Navigator.of(ctx);
                              try {
                                await _api(context).restoreVersion(widget.file.id, v.id);
                                nav.pop();
                                if (context.mounted) _snack(context, 'Version restored');
                                widget.onRestored?.call();
                              } catch (e) {
                                if (context.mounted) _snack(context, 'Restore failed: $e', err: true);
                              }
                            },
                            child: const Text('Restore'),
                          ),
                  )).toList()),
    ));
  }
}

// ── Comments ────────────────────────────────────────────────────────────────

void showDriveCommentsSheet(BuildContext context, DriveFile file) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true, // reliable drag-to-dismiss even when full-height
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    // Read the keyboard inset from the SHEET's context (ctx), not the caller's —
    // the caller isn't rebuilt when the keyboard opens, so it never lifted before.
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: _CommentsSheet(file: file),
    ),
  );
}

class _CommentsSheet extends StatefulWidget {
  final DriveFile file;
  const _CommentsSheet({required this.file});
  @override
  State<_CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends State<_CommentsSheet> {
  final _ctrl = TextEditingController();
  late Future<List<DriveComment>> _future;
  @override
  void initState() {
    super.initState();
    _future = _api(context).listComments(widget.file.id);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _reload() {
    final f = _api(context).listComments(widget.file.id);
    setState(() { _future = f; });
  }

  // Commenting needs at least the "commenter" role. Items you own send no role
  // (myRole == null) → you can comment. Viewers (below commenter) cannot.
  bool get _canComment => (widget.file.myRole?.rank ?? 99) >= DriveRole.commenter.rank;

  @override
  Widget build(BuildContext context) {
    return _panel(context, Icons.comment_outlined, 'Comments', Column(children: [
      Expanded(
        child: FutureBuilder<List<DriveComment>>(
          future: _future,
          builder: (ctx, snap) => snap.connectionState == ConnectionState.waiting
              ? const Center(child: CircularProgressIndicator(color: AppColors.green700))
              : (snap.data?.isEmpty ?? true)
                  ? const Center(child: Text('No comments yet', style: TextStyle(color: AppColors.muted)))
                  : ListView(children: snap.data!.map((c) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          CircleAvatar(radius: 14, backgroundColor: AppColors.green700, child: Text(c.authorName.isNotEmpty ? c.authorName[0].toUpperCase() : '?', style: const TextStyle(color: AppColors.white, fontSize: 11))),
                          const SizedBox(width: 10),
                          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              Text(c.authorName, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.heading)),
                              const SizedBox(width: 6),
                              Text(_ago(c.createdAt), style: const TextStyle(fontSize: 10, color: AppColors.muted)),
                            ]),
                            Text(c.body, style: const TextStyle(fontSize: 13, color: AppColors.body)),
                          ])),
                        ]),
                      )).toList()),
        ),
      ),
      if (_canComment)
        Row(children: [
          Expanded(child: TextField(controller: _ctrl, decoration: InputDecoration(hintText: 'Add a comment…', filled: true, fillColor: AppColors.grey96, border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none), contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10)))),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.send, color: AppColors.green700),
            onPressed: () async {
              final body = _ctrl.text.trim();
              if (body.isEmpty) return;
              _ctrl.clear();
              try {
                await _api(context).addComment(widget.file.id, body);
                _reload();
              } catch (e) {
                final msg = (e is DriveException && (e.isAuth || e.code == 'not_found' || e.code == 'permission_denied'))
                    ? 'You don\'t have permission to comment here.'
                    : 'Comment failed: ${e is DriveException ? e.message : e}';
                if (context.mounted) _snack(context, msg, err: true);
              }
            },
          ),
        ])
      else
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text('You have view-only access — commenting is disabled.', style: TextStyle(fontSize: 12, color: AppColors.muted)),
        ),
    ]));
  }
}

// ── Activity ────────────────────────────────────────────────────────────────

void showDriveActivitySheet(BuildContext context, DriveFile file) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (_) => _panel(context, Icons.history_toggle_off, 'Activity', FutureBuilder<List<DriveActivity>>(
      future: _api(context).fileActivity(file.id),
      builder: (ctx, snap) => snap.connectionState == ConnectionState.waiting
          ? const Center(child: CircularProgressIndicator(color: AppColors.green700))
          : (snap.data?.isEmpty ?? true)
              ? const Center(child: Text('No activity yet', style: TextStyle(color: AppColors.muted)))
              : ListView(children: snap.data!.map((a) {
                  final label = a.action.replaceAll('.', ' ');
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Container(width: 32, height: 32, decoration: BoxDecoration(color: AppColors.greenActiveBg, borderRadius: BorderRadius.circular(8)), child: const Icon(Icons.bolt, size: 16, color: AppColors.green700)),
                      const SizedBox(width: 10),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(label, style: const TextStyle(fontSize: 13, color: AppColors.heading)),
                        Text(_ago(a.occurredAt), style: const TextStyle(fontSize: 11, color: AppColors.muted)),
                      ])),
                    ]),
                  );
                }).toList()),
    )),
  );
}

// ── Expiration ──────────────────────────────────────────────────────────────

Future<void> showDriveExpirationDialog(BuildContext context, DriveFile file, {VoidCallback? onChanged}) async {
  final api = _api(context);
  // Fetch the CURRENT expiration fresh — the file passed from the list may be
  // stale (e.g. one was just set), which would hide the "Remove expiry" option.
  DateTime? current = file.expiresAt;
  try {
    final detail = await api.fileDetail(file.id);
    current = detail.expiresAt;
  } catch (_) {}
  if (!context.mounted) return;
  final action = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Expiration — ${file.name}', overflow: TextOverflow.ellipsis),
      content: Text(current != null
          ? 'This item expires on ${DateFormat('MMM d, y  h:mm a').format(current.toLocal())}.'
          : 'Set a date and time after which this item is automatically removed.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        if (current != null)
          TextButton(onPressed: () => Navigator.pop(ctx, 'clear'), child: const Text('Remove expiry', style: TextStyle(color: AppColors.filePdf))),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, 'set'), child: Text(current != null ? 'Change date' : 'Set date')),
      ],
    ),
  );
  if (action == null) return;
  if (!context.mounted) return;
  if (action == 'clear') {
    try {
      await api.setExpiration(file.id, null);
      onChanged?.call();
      if (context.mounted) _snack(context, 'Expiration removed');
    } catch (e) {
      if (context.mounted) _snack(context, 'Failed: $e', err: true);
    }
    return;
  }
  final initial = current ?? DateTime.now().add(const Duration(days: 30));
  final date = await showDatePicker(
    context: context,
    initialDate: initial,
    firstDate: DateTime.now(),
    lastDate: DateTime.now().add(const Duration(days: 3650)),
  );
  if (date == null || !context.mounted) return;
  // Then pick the time of day (hours/minutes), like the Drive.
  final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(initial));
  final t = time ?? const TimeOfDay(hour: 23, minute: 59); // default to end of day
  final when = DateTime(date.year, date.month, date.day, t.hour, t.minute);
  if (!context.mounted) return;
  try {
    await api.setExpiration(file.id, when);
    onChanged?.call();
    if (context.mounted) _snack(context, 'Expires ${DateFormat('MMM d, y  h:mm a').format(when)}');
  } catch (e) {
    if (context.mounted) _snack(context, 'Failed: $e', err: true);
  }
}

// ── shared panel chrome ─────────────────────────────────────────────────────

Widget _panel(BuildContext context, IconData icon, String title, Widget body) {
  final mq = MediaQuery.of(context);
  // Cap the card to the space left above the keyboard, so with the input focused
  // it lifts and stays fully visible instead of being covered/clipped.
  final available = mq.size.height - mq.viewInsets.bottom - mq.padding.top - 48;
  final target = mq.size.height * 0.6;
  final double h = target < available ? target : (available > 220 ? available : 220.0);
  return Container(
      height: h,
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Icon(icon, color: AppColors.green800, size: 20), const SizedBox(width: 8), Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.heading))]),
        const SizedBox(height: 12),
        const Divider(),
        Expanded(child: body),
      ]),
  );
}
