// drive_dashboard.dart — overview screen for the new Drive.
// Storage breakdown comes from GET /quota buckets (server-side categorization),
// replacing the old client-side mime bucketing.

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../config/theme.dart';
import '../../models/drive_file.dart';
import '../../services/drive/drive_account_manager.dart';
import '../../services/drive/drive_cache.dart';
import 'drive_open_file.dart';

class DriveDashboard extends StatelessWidget {
  final VoidCallback onNavigateToFiles;
  const DriveDashboard({super.key, required this.onNavigateToFiles});

  String _fmt(int bytes) {
    final b = bytes.toDouble();
    if (b < 1024) return '${b.toInt()} B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final cache = context.watch<DriveCache>();
    final mgr = context.watch<DriveAccountManager>();
    if (cache.isFirstLoad) {
      return const Center(child: CircularProgressIndicator(color: AppColors.green700));
    }

    final root = cache.rootFiles;
    final files = root.where((f) => !f.isDirectory).length;
    final folders = root.where((f) => f.isDirectory).length;
    final recent = cache.recentFiles.where((f) => !f.isDirectory).take(4).toList();
    final q = cache.quota;
    final used = q?.usedBytes ?? 0;
    final total = q?.limitBytes ?? -1;
    final isMobile = MediaQuery.of(context).size.width < 600;

    return RefreshIndicator(
      color: AppColors.green700,
      onRefresh: cache.refresh,
      child: ListView(padding: EdgeInsets.all(isMobile ? 16 : 24), children: [
        if (cache.quotaWarningLevel != 'ok')
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: (cache.quotaWarningLevel == 'critical' ? AppColors.filePdf : AppColors.fileAi).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(children: [
              Icon(Icons.warning_amber_rounded, size: 20, color: cache.quotaWarningLevel == 'critical' ? AppColors.filePdf : AppColors.fileAi),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Storage ${cache.quotaWarningLevel == 'critical' ? 'almost full' : 'running low'} (${total > 0 ? ((used / total) * 100).toInt() : 0}% used)',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cache.quotaWarningLevel == 'critical' ? AppColors.filePdf : AppColors.fileAi),
                ),
              ),
            ]),
          ),

        // Welcome banner
        Container(
          padding: EdgeInsets.all(isMobile ? 14 : 20),
          decoration: BoxDecoration(color: AppColors.azure17, borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            ClipRRect(borderRadius: BorderRadius.circular(22), child: Image.asset('assets/logo.png', width: 44, height: 44)),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('WorldPosta Drive', style: TextStyle(color: AppColors.white, fontWeight: FontWeight.w600, fontSize: 15)),
                Text('Your cloud storage, secured and simplified.',
                    style: TextStyle(color: AppColors.white.withValues(alpha: 0.7), fontSize: 13)),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 24),

        Text('Overview', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.heading)),
        Text('Welcome back, ${mgr.activeAccount?.displayName ?? 'User'}.', style: const TextStyle(fontSize: 14, color: AppColors.body)),
        const SizedBox(height: 20),

        // Stats
        LayoutBuilder(builder: (context, c) {
          final mob = c.maxWidth < 500;
          final w = mob ? (c.maxWidth - 16) / 2 : (c.maxWidth - 48) / 4;
          return Wrap(spacing: mob ? 12 : 16, runSpacing: mob ? 12 : 16, children: [
            _stat('Files', '$files', '$folders folders', w.clamp(140.0, 260.0), mob),
            _stat('Storage Used', _fmt(used), total > 0 ? '${((used / total) * 100).toInt()}% of ${_fmt(total)}' : 'Unlimited', w.clamp(140.0, 260.0), mob),
            _stat('Shared', '${cache.sharedByMe.length}', 'by you', w.clamp(140.0, 260.0), mob),
            _stat('Starred', '${cache.starredFiles.length}', '', w.clamp(140.0, 260.0), mob),
          ]);
        }),
        const SizedBox(height: 24),

        LayoutBuilder(builder: (context, c) {
          final wide = c.maxWidth > 700;
          final recentCard = _recentCard(context, recent);
          final storageCard = _storageCard(cache, used, total);
          return wide
              ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(flex: 2, child: recentCard),
                  const SizedBox(width: 16),
                  Expanded(child: storageCard),
                ])
              : Column(children: [recentCard, const SizedBox(height: 16), storageCard]);
        }),
      ]),
    );
  }

  Widget _stat(String label, String value, String sub, double width, bool compact) => Container(
        width: width,
        padding: EdgeInsets.all(compact ? 12 : 20),
        decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.grey91)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(fontSize: compact ? 11 : 13, color: AppColors.body)),
          SizedBox(height: compact ? 4 : 8),
          Text(value, style: TextStyle(fontSize: compact ? 20 : 28, fontWeight: FontWeight.w700, color: AppColors.heading), overflow: TextOverflow.ellipsis),
          if (sub.isNotEmpty) Text(sub, style: TextStyle(fontSize: compact ? 10 : 12, color: AppColors.green700), overflow: TextOverflow.ellipsis),
        ]),
      );

  Widget _recentCard(BuildContext context, List<DriveFile> recent) => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.grey91)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Text('Recent Files', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.heading)),
            const Spacer(),
            TextButton(onPressed: onNavigateToFiles, child: const Text('View All', style: TextStyle(color: AppColors.green700, fontSize: 13))),
          ]),
          const SizedBox(height: 8),
          if (recent.isEmpty)
            const Padding(padding: EdgeInsets.all(20), child: Center(child: Text('No files yet.', style: TextStyle(color: AppColors.muted))))
          else
            ...recent.map((f) => InkWell(
                  onTap: () => openDriveFile(context, f),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(children: [
                      const Icon(Icons.insert_drive_file_outlined, size: 28, color: AppColors.azure47),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(f.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: AppColors.heading), overflow: TextOverflow.ellipsis),
                          Text('${f.updatedAt != null ? DateFormat('MMM d, y').format(f.updatedAt!.toLocal()) : ''}  ${f.sizeFormatted}',
                              style: const TextStyle(fontSize: 12, color: AppColors.muted)),
                        ]),
                      ),
                    ]),
                  ),
                )),
        ]),
      );

  Widget _storageCard(DriveCache cache, int used, int total) {
    final buckets = cache.quota?.buckets ?? [];
    final colors = [AppColors.green700, AppColors.filePsd, AppColors.filePng, AppColors.fileHtml, AppColors.fileAi];
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.grey91)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Storage', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.heading)),
        const SizedBox(height: 8),
        Text(total > 0 ? '${_fmt(used)} / ${_fmt(total)}' : _fmt(used),
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.heading)),
        const SizedBox(height: 12),
        if (total > 0)
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: (used / total).clamp(0.0, 1.0),
              backgroundColor: AppColors.grey91,
              valueColor: const AlwaysStoppedAnimation(AppColors.green800),
              minHeight: 8,
            ),
          ),
        const SizedBox(height: 16),
        ...buckets.asMap().entries.map((e) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: [
                Container(width: 10, height: 10, decoration: BoxDecoration(color: colors[e.key % colors.length], shape: BoxShape.circle)),
                const SizedBox(width: 8),
                Text(_cap(e.value.category), style: const TextStyle(fontSize: 13, color: AppColors.body)),
                const Spacer(),
                Text(_fmt(e.value.bytes), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.heading)),
              ]),
            )),
      ]),
    );
  }

  String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}
