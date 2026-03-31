import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../config/theme.dart';
import '../services/data_cache_service.dart';

class ActivityScreen extends StatelessWidget {
  const ActivityScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cache = context.watch<DataCacheService>();
    final activities = cache.activityFeed;

    return RefreshIndicator(
      onRefresh: cache.refresh,
      child: activities.isEmpty
          ? ListView(
              children: const [
                SizedBox(height: 120),
                Center(
                  child: Text(
                    'No activity yet.',
                    style: TextStyle(color: AppColors.muted, fontSize: 14),
                  ),
                ),
              ],
            )
          : ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              itemCount: activities.length,
              separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.grey91),
              itemBuilder: (context, index) {
                final activity = activities[index];
                return _ActivityTile(activity: activity);
              },
            ),
    );
  }
}

class _ActivityTile extends StatelessWidget {
  final Map<String, dynamic> activity;

  const _ActivityTile({required this.activity});

  @override
  Widget build(BuildContext context) {
    final subject = activity['subject'] as String? ?? '';
    final user = activity['user'] as String? ?? '';
    final type = activity['type'] as String? ?? '';
    final dateStr = activity['datetime'] as String? ?? activity['date'] as String? ?? '';
    final icon = activity['icon'] as String? ?? '';

    DateTime? timestamp;
    if (dateStr.isNotEmpty) {
      try {
        timestamp = DateTime.parse(dateStr);
      } catch (_) {}
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: _colorForType(type).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              _iconForType(type, icon),
              size: 18,
              color: _colorForType(type),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  subject,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AppColors.heading,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    if (user.isNotEmpty) ...[
                      Text(
                        user,
                        style: const TextStyle(fontSize: 12, color: AppColors.body),
                      ),
                      const SizedBox(width: 8),
                    ],
                    if (timestamp != null)
                      Text(
                        _formatTimestamp(timestamp),
                        style: const TextStyle(fontSize: 11, color: AppColors.muted),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  IconData _iconForType(String type, String iconUrl) {
    switch (type) {
      case 'file_created':
        return Icons.note_add_outlined;
      case 'file_changed':
        return Icons.edit_outlined;
      case 'file_deleted':
        return Icons.delete_outline;
      case 'file_restored':
        return Icons.restore;
      case 'shared':
      case 'remote_share':
      case 'public_links':
        return Icons.share_outlined;
      case 'comments':
        return Icons.comment_outlined;
      case 'security':
        return Icons.security_outlined;
      default:
        if (iconUrl.contains('delete')) return Icons.delete_outline;
        if (iconUrl.contains('share')) return Icons.share_outlined;
        if (iconUrl.contains('change') || iconUrl.contains('edit')) return Icons.edit_outlined;
        if (iconUrl.contains('add') || iconUrl.contains('create')) return Icons.note_add_outlined;
        return Icons.history;
    }
  }

  Color _colorForType(String type) {
    switch (type) {
      case 'file_created':
        return AppColors.green700;
      case 'file_changed':
        return AppColors.fileHtml;
      case 'file_deleted':
        return AppColors.filePdf;
      case 'file_restored':
        return AppColors.green800;
      case 'shared':
      case 'remote_share':
      case 'public_links':
        return AppColors.filePsd;
      case 'comments':
        return AppColors.fileAi;
      case 'security':
        return AppColors.filePdf;
      default:
        return AppColors.azure47;
    }
  }

  String _formatTimestamp(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.month}/${dt.day}/${dt.year}';
  }
}
