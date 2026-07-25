// drive_activity_screen.dart — the caller's recent activity (GET /me/activity),
// merged with optimistic local events from DriveCache.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../config/theme.dart';
import '../../services/drive/drive_api.dart';
import '../../services/drive/drive_cache.dart';

class DriveActivityScreen extends StatelessWidget {
  const DriveActivityScreen({super.key});

  IconData _icon(String action) {
    final a = action.toLowerCase();
    if (a.contains('delet')) return Icons.delete_outline;
    if (a.contains('creat') || a.contains('upload')) return Icons.note_add_outlined;
    if (a.contains('renam') || a.contains('mov') || a.contains('updat') || a.contains('edit')) return Icons.edit_outlined;
    if (a.contains('shar') || a.contains('permission')) return Icons.share_outlined;
    if (a.contains('restor')) return Icons.restore;
    return Icons.history;
  }

  Color _color(String action) {
    final a = action.toLowerCase();
    if (a.contains('delet')) return AppColors.filePdf;
    if (a.contains('creat') || a.contains('upload')) return AppColors.green700;
    if (a.contains('shar')) return AppColors.filePsd;
    return AppColors.azure47;
  }

  String _ago(DateTime? d) {
    if (d == null) return '';
    final diff = DateTime.now().difference(d);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${d.month}/${d.day}/${d.year}';
  }

  String _label(DriveActivity a) {
    // Server actions are dotted verbs (file.created.webdav, permission.granted…).
    return a.action.replaceAll('.webdav', '').replaceAll('.', ' ');
  }

  @override
  Widget build(BuildContext context) {
    final cache = context.watch<DriveCache>();
    final items = cache.mergedActivityFeed;
    return RefreshIndicator(
      color: AppColors.green700,
      onRefresh: cache.refresh,
      child: items.isEmpty
          ? ListView(children: const [SizedBox(height: 120), Center(child: Text('No activity yet.', style: TextStyle(color: AppColors.muted, fontSize: 14)))])
          : ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              itemCount: items.length,
              separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.grey91),
              itemBuilder: (context, i) {
                final a = items[i];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(color: _color(a.action).withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
                      child: Icon(_icon(a.action), size: 18, color: _color(a.action)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(_label(a), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppColors.heading)),
                        const SizedBox(height: 2),
                        Text('${a.outcome.isNotEmpty ? '${a.outcome} · ' : ''}${_ago(a.occurredAt)}',
                            style: const TextStyle(fontSize: 11, color: AppColors.muted)),
                      ]),
                    ),
                  ]),
                );
              },
            ),
    );
  }
}
