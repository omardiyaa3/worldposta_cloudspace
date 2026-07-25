// drive_sync_monitor.dart — live sync status, counters, and log.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../config/theme.dart';
import '../../services/drive/drive_sync_service.dart';

class DriveSyncMonitor extends StatelessWidget {
  const DriveSyncMonitor({super.key});

  @override
  Widget build(BuildContext context) {
    DriveSyncService? sync;
    try {
      sync = context.watch<DriveSyncService>();
    } catch (_) {
      return const Scaffold(body: Center(child: Text('Sync not available')));
    }
    final s = sync;
    return Scaffold(
      backgroundColor: AppColors.grey98,
      appBar: AppBar(
        title: const Text('Sync Monitor', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        backgroundColor: AppColors.white,
        foregroundColor: AppColors.heading,
        elevation: 0,
        actions: [
          if (s.isSyncing)
            const Padding(padding: EdgeInsets.all(16), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.green700)))
          else if (s.syncFolder != null)
            IconButton(icon: const Icon(Icons.sync, color: AppColors.green700), tooltip: 'Sync now', onPressed: () { if (!s.isEnabled) s.start(); s.syncNow(); }),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(s.isSyncing ? Icons.sync : Icons.cloud_done, color: s.isSyncing ? AppColors.green700 : AppColors.azure65, size: 20),
              const SizedBox(width: 8),
              Expanded(child: Text(s.status, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.heading))),
            ]),
            if (s.syncFolder != null) ...[
              const SizedBox(height: 4),
              Text(s.syncFolder!, style: const TextStyle(fontSize: 12, color: AppColors.body), overflow: TextOverflow.ellipsis),
            ],
            if (s.isSyncing && s.currentFile.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('Working on: ${s.currentFile}', style: const TextStyle(fontSize: 12, fontFamily: 'monospace', color: AppColors.green800), overflow: TextOverflow.ellipsis),
            ],
          ])),
          const SizedBox(height: 12),
          _card(child: Row(children: [
            _stat(Icons.download, '${s.downloaded}', 'Down', AppColors.green700),
            _stat(Icons.upload, '${s.uploaded}', 'Up', AppColors.azure47),
            _stat(Icons.delete_outline, '${s.deleted}', 'Removed', AppColors.away),
            _stat(Icons.error_outline, '${s.errors}', 'Errors', AppColors.filePdf),
          ])),
          const SizedBox(height: 12),
          _card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Sync Log', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.heading)),
            const SizedBox(height: 8),
            Container(
              height: 320,
              decoration: BoxDecoration(color: AppColors.grey96, borderRadius: BorderRadius.circular(8)),
              child: s.log.isEmpty
                  ? const Center(child: Text('No log entries yet.', style: TextStyle(color: AppColors.muted, fontSize: 13)))
                  : ListView.builder(
                      padding: const EdgeInsets.all(8),
                      itemCount: s.log.length,
                      itemBuilder: (_, i) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1),
                        child: Text(s.log[i], style: TextStyle(fontSize: 11, fontFamily: 'monospace', color: s.log[i].contains('FAIL') || s.log[i].contains('ERROR') ? AppColors.filePdf : s.log[i].startsWith('download') || s.log[i].startsWith('upload') ? AppColors.green800 : AppColors.body)),
                      ),
                    ),
            ),
          ])),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: ElevatedButton.icon(
              onPressed: s.syncFolder != null ? () { if (!s.isEnabled) s.start(); s.syncNow(); } : null,
              icon: const Icon(Icons.sync, size: 18),
              label: const Text('Sync Now'),
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.green800, foregroundColor: AppColors.white, padding: const EdgeInsets.symmetric(vertical: 12)),
            )),
            const SizedBox(width: 12),
            Expanded(child: OutlinedButton.icon(
              onPressed: s.isEnabled ? () => s.stop() : null,
              icon: const Icon(Icons.stop, size: 18),
              label: const Text('Stop Sync'),
              style: OutlinedButton.styleFrom(foregroundColor: AppColors.filePdf, side: const BorderSide(color: AppColors.filePdf), padding: const EdgeInsets.symmetric(vertical: 12)),
            )),
          ]),
        ]),
      ),
    );
  }

  Widget _card({required Widget child}) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.grey91)),
        child: child,
      );

  Widget _stat(IconData icon, String value, String label, Color color) => Expanded(
        child: Column(children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(height: 2),
          Text(value, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: color)),
          Text(label, style: const TextStyle(fontSize: 10, color: AppColors.body)),
        ]),
      );
}
