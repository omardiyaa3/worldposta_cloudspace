// drive_sync_config.dart — sync options: who wins on conflict, which direction
// files flow, and the schedule (immediate vs periodic + interval).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../config/theme.dart';
import '../../services/drive/drive_sync_service.dart';

class DriveSyncConfig extends StatelessWidget {
  const DriveSyncConfig({super.key});

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<DriveSyncService>();
    final isMobile = MediaQuery.of(context).size.width < 600;
    return Scaffold(
      backgroundColor: AppColors.grey98,
      appBar: AppBar(
        title: const Text('Sync Options', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        backgroundColor: AppColors.white,
        foregroundColor: AppColors.heading,
        elevation: 0,
      ),
      body: ListView(
        padding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 24, vertical: 16),
        children: [
          // ── Conflict resolution ──
          _card('Conflict Resolution', Icons.merge_type, [
            const Text('When the same file changed both on your computer and on the Drive since the last sync, who wins?',
                style: TextStyle(fontSize: 13, color: AppColors.body)),
            const SizedBox(height: 12),
            _dropdown<ConflictPolicy>(
              value: sync.conflictPolicy,
              items: const {
                ConflictPolicy.newestWins: 'Newest wins (recommended)',
                ConflictPolicy.serverWins: 'Server (Drive) wins',
                ConflictPolicy.localWins: 'Local (this computer) wins',
              },
              onChanged: (v) => sync.setConflictPolicy(v),
            ),
          ]),
          const SizedBox(height: 16),

          // ── Direction ──
          _card('Sync Direction', Icons.swap_vert, [
            const Text('Which way files flow between this folder and the Drive.', style: TextStyle(fontSize: 13, color: AppColors.body)),
            const SizedBox(height: 12),
            _dropdown<SyncDirection>(
              value: sync.syncDirection,
              items: const {
                SyncDirection.twoWay: 'Two-way (both directions)',
                SyncDirection.downloadOnly: 'Download only (Drive → computer)',
                SyncDirection.uploadOnly: 'Upload only (computer → Drive)',
              },
              onChanged: (v) => sync.setSyncDirection(v),
            ),
            if (sync.syncDirection == SyncDirection.downloadOnly)
              const Padding(padding: EdgeInsets.only(top: 8), child: Text('Local edits are replaced by the Drive copy.', style: TextStyle(fontSize: 11, color: AppColors.muted))),
            if (sync.syncDirection == SyncDirection.uploadOnly)
              const Padding(padding: EdgeInsets.only(top: 8), child: Text('The Drive is never written over by deletions; only your local files are pushed up.', style: TextStyle(fontSize: 11, color: AppColors.muted))),
          ]),
          const SizedBox(height: 16),

          // ── Schedule ──
          _card('Schedule', Icons.schedule, [
            const Text('How often to check for changes.', style: TextStyle(fontSize: 13, color: AppColors.body)),
            const SizedBox(height: 12),
            _dropdown<bool>(
              value: sync.isPeriodic,
              items: const {
                false: 'Immediate (watch for changes)',
                true: 'Periodic (on a timer)',
              },
              onChanged: (v) => sync.setSchedule(periodic: v),
            ),
            if (sync.isPeriodic) ...[
              const SizedBox(height: 16),
              Text('Every ${sync.intervalSeconds}s', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppColors.heading)),
              Slider(
                value: sync.intervalSeconds.toDouble().clamp(10, 600),
                min: 10,
                max: 600,
                divisions: 59,
                activeColor: AppColors.green800,
                inactiveColor: AppColors.grey91,
                label: '${sync.intervalSeconds}s',
                onChanged: (v) => sync.setSchedule(intervalSeconds: v.round()),
              ),
              const Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text('10s', style: TextStyle(fontSize: 11, color: AppColors.muted)),
                Text('10 min', style: TextStyle(fontSize: 11, color: AppColors.muted)),
              ]),
            ] else
              const Padding(padding: EdgeInsets.only(top: 8), child: Text('Syncs the moment a file changes, with a 30-second safety check.', style: TextStyle(fontSize: 11, color: AppColors.muted))),
          ]),
          const SizedBox(height: 16),

          // ── Maintenance ──
          _card('Maintenance', Icons.build_outlined, [
            const Text('If the two sides have drifted apart or you\'ve cleaned up duplicates, reset the sync bookkeeping. This re-baselines on the next sync and does NOT delete any files.',
                style: TextStyle(fontSize: 13, color: AppColors.body)),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: sync.syncFolder == null
                  ? null
                  : () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('Reset sync state?'),
                          content: const Text('This forgets what\'s already synced and re-checks everything by content on the next sync. No files are deleted.'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reset')),
                          ],
                        ),
                      );
                      if (ok == true) {
                        await sync.resetSyncState();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Sync state reset — it will re-baseline on the next sync'), backgroundColor: AppColors.green700),
                          );
                        }
                      }
                    },
              icon: const Icon(Icons.restart_alt, size: 18),
              label: const Text('Reset Sync State'),
              style: OutlinedButton.styleFrom(foregroundColor: AppColors.filePdf, side: const BorderSide(color: AppColors.filePdf)),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _card(String title, IconData icon, List<Widget> children) => Card(
        color: AppColors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: AppColors.grey91)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(icon, size: 20, color: AppColors.green800),
              const SizedBox(width: 8),
              Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.heading)),
            ]),
            const SizedBox(height: 12),
            const Divider(height: 1, color: AppColors.grey91),
            const SizedBox(height: 12),
            ...children,
          ]),
        ),
      );

  Widget _dropdown<T>({required T value, required Map<T, String> items, required ValueChanged<T> onChanged}) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(color: AppColors.grey96, borderRadius: BorderRadius.circular(8)),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<T>(
            value: value,
            isExpanded: true,
            items: items.entries.map((e) => DropdownMenuItem<T>(value: e.key, child: Text(e.value))).toList(),
            onChanged: (v) { if (v != null) onChanged(v); },
            style: const TextStyle(fontSize: 14, color: AppColors.heading),
            dropdownColor: AppColors.white,
          ),
        ),
      );
}
