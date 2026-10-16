// drive_settings_screen.dart — account + about. Sync/bandwidth settings return
// when the sync engine is ported (Phase 4).

import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import '../../config/theme.dart';
import '../../services/drive/drive_account_manager.dart';
import '../../services/drive/drive_client.dart';
import '../../services/drive/drive_sync_service.dart';
import 'drive_sync_config.dart';
import 'drive_sync_monitor.dart';

class DriveSettingsScreen extends StatelessWidget {
  const DriveSettingsScreen({super.key});

  // Per-account subfolder (e.g. "CloudSpace/user@worldposta.com") so two accounts
  // never sync into the SAME folder and clobber each other's files.
  String _accountFolder(BuildContext context, DriveSyncService sync) {
    final a = context.read<DriveAccountManager>().activeAccount;
    final raw = (a != null && a.email.isNotEmpty) ? a.email : sync.accountId;
    final safe = raw.replaceAll(RegExp(r'[^A-Za-z0-9._@-]'), '_');
    return 'CloudSpace/${safe.isEmpty ? sync.accountId : safe}';
  }

  // Resolve the Android sync folder as a TOP-LEVEL public folder under
  // /storage/emulated/0/<rel> (rel = "CloudSpace/<account>"), visible in the Files
  // app alongside Download/DCIM. Needs storage permission (All-files access on
  // Android 11+; legacy write on ≤10). Falls back to the app's external files dir.
  Future<String?> _androidSyncPath(BuildContext context, String rel) async {
    final messenger = ScaffoldMessenger.of(context); // capture before async gaps
    final ext = await getExternalStorageDirectory(); // …/Android/data/<pkg>/files
    final idx = ext?.path.indexOf('/Android/') ?? -1;
    String? top = (ext != null && idx > 0) ? '${ext.path.substring(0, idx)}/$rel' : null;

    if (top != null) {
      await Permission.storage.request(); // legacy write (Android ≤10/12)
      if (!await _tryCreateWritable(top)) {
        await Permission.manageExternalStorage.request(); // All-files access (11+)
        if (!await _tryCreateWritable(top)) top = null;
      }
    }
    if (top != null) return top;

    // Fallback: app external files dir (visible under Android/data/<pkg>/files).
    messenger.showSnackBar(const SnackBar(
      content: Text('Storage permission not granted — syncing to the app folder instead.'),
      backgroundColor: AppColors.filePdf,
    ));
    final base = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
    return '${base.path}/$rel';
  }

  Future<bool> _tryCreateWritable(String p) async {
    try {
      final d = Directory(p);
      if (!await d.exists()) await d.create(recursive: true);
      final probe = File('$p/.cs_write_test');
      await probe.writeAsString('x');
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _pickFolder(BuildContext context, DriveSyncService sync) async {
    String? path;
    if (Platform.isIOS || Platform.isAndroid) {
      // Mobile apps are sandboxed — there's no system folder browser to pick an
      // arbitrary directory. CloudSpace syncs to its own folder, which iOS exposes
      // in the Files app (On My iPhone → CloudSpace) and Android under the app's
      // storage. Confirm first so the button gives clear feedback.
      final where = Platform.isIOS
          ? 'the Files app under “On My iPhone → CloudSpace”'
          : 'your phone storage as a top-level “CloudSpace” folder (needs storage permission)';
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Sync folder'),
          content: Text(
            'On this device, apps can’t sync to an arbitrary folder. Posta Drive will '
            'sync to its own folder — you can open it in $where.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.green700, foregroundColor: AppColors.white),
              child: const Text('Enable Sync'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      if (!context.mounted) return;
      final rel = _accountFolder(context, sync); // e.g. "CloudSpace/user@worldposta.com"
      if (Platform.isAndroid) {
        path = await _androidSyncPath(context, rel);
      } else {
        final base = await getApplicationDocumentsDirectory();
        path = '${base.path}/$rel';
      }
    } else {
      path = await FilePicker.platform.getDirectoryPath(dialogTitle: 'Choose a local folder to sync');
    }
    if (path == null) return;
    try {
      await sync.setFolder(path);
      sync.start();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not start sync: ${friendlyError(e)}'), backgroundColor: AppColors.filePdf),
        );
      }
      return;
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Syncing ${path.split(Platform.pathSeparator).last} ↔ Drive'), backgroundColor: AppColors.green700),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final mgr = context.watch<DriveAccountManager>();
    final a = mgr.activeAccount;
    DriveSyncService? sync;
    try {
      sync = context.watch<DriveSyncService>();
    } catch (_) {}
    final isMobile = MediaQuery.of(context).size.width < 600;
    return ListView(
      padding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 24, vertical: isMobile ? 16 : 24),
      children: [
        const Text('Settings', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: AppColors.heading)),
        const SizedBox(height: 24),
        _card('Account', Icons.person_outline, [
          _field('Name', a?.displayName ?? '—'),
          const SizedBox(height: 12),
          _field('Email', a?.email ?? '—'),
          const SizedBox(height: 12),
          _field('Server', a?.serverUrl ?? '—'),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: ElevatedButton.icon(
              onPressed: () => mgr.logoutCurrent(),
              icon: const Icon(Icons.logout, size: 18),
              label: const Text('Log Out'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.filePdf,
                foregroundColor: AppColors.white,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
        ]),
        const SizedBox(height: 16),
        if (sync != null)
          _card('Folder Sync', Icons.sync, [
            _field('Sync folder', sync.syncFolder != null ? sync.syncFolder!.split(Platform.pathSeparator).last : 'Not configured'),
            const SizedBox(height: 8),
            Text(
              'Two-way sync. New/changed files copy both ways; deleting a cloud file removes the local copy. Deleting a local file re-downloads it — remove cloud files from the app, not the folder.',
              style: const TextStyle(fontSize: 11, color: AppColors.muted),
            ),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(
                onPressed: () => _pickFolder(context, sync!),
                icon: const Icon(Icons.folder_open, size: 18),
                label: Text(sync.syncFolder == null ? 'Choose Folder' : 'Change Folder'),
                style: OutlinedButton.styleFrom(foregroundColor: AppColors.green800, side: const BorderSide(color: AppColors.green800), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
              ),
              if (sync.syncFolder != null && !sync.isEnabled)
                ElevatedButton.icon(onPressed: () => sync!.start(), icon: const Icon(Icons.play_arrow, size: 18), label: const Text('Start'), style: ElevatedButton.styleFrom(backgroundColor: AppColors.green700, foregroundColor: AppColors.white)),
              if (sync.isEnabled)
                OutlinedButton.icon(onPressed: () => sync!.stop(), icon: const Icon(Icons.stop, size: 18), label: const Text('Stop'), style: OutlinedButton.styleFrom(foregroundColor: AppColors.filePdf, side: const BorderSide(color: AppColors.filePdf))),
              if (sync.syncFolder != null)
                TextButton.icon(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DriveSyncMonitor())),
                  icon: const Icon(Icons.monitor_heart_outlined, size: 18, color: AppColors.green700),
                  label: const Text('Monitor', style: TextStyle(color: AppColors.green700)),
                ),
              TextButton.icon(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DriveSyncConfig())),
                icon: const Icon(Icons.tune, size: 18, color: AppColors.green700),
                label: const Text('Sync Options', style: TextStyle(color: AppColors.green700)),
              ),
            ]),
          ]),
        const SizedBox(height: 16),
        _card('About', Icons.info_outline, [_field('Version', '2.0.0 (Drive)')]),
      ],
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
            const SizedBox(height: 16),
            const Divider(height: 1, color: AppColors.grey91),
            const SizedBox(height: 16),
            ...children,
          ]),
        ),
      );

  Widget _field(String label, String value) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppColors.body)),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(color: AppColors.grey96, borderRadius: BorderRadius.circular(8)),
          child: Text(value, style: const TextStyle(fontSize: 14, color: AppColors.heading)),
        ),
      ]);
}
