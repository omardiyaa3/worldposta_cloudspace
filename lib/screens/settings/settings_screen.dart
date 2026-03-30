import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../config/theme.dart';
import '../../services/auth_service.dart';
import '../../services/sync_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _periodicSync = false;
  double _syncIntervalSec = 30;
  late TextEditingController _downloadLimitCtrl;
  late TextEditingController _uploadLimitCtrl;
  String _defaultDownloadPath = '';

  @override
  void initState() {
    super.initState();
    _loadDownloadPath();
    final sync = context.read<SyncService>();
    final dlMb = sync.downloadBytesPerSec / (1024 * 1024);
    final ulMb = sync.uploadBytesPerSec / (1024 * 1024);
    _downloadLimitCtrl = TextEditingController(
      text: dlMb > 0 ? dlMb.toStringAsFixed(1) : '0',
    );
    _uploadLimitCtrl = TextEditingController(
      text: ulMb > 0 ? ulMb.toStringAsFixed(1) : '0',
    );
  }

  Future<void> _loadDownloadPath() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _defaultDownloadPath = prefs.getString('default_download_path') ?? '');
  }

  @override
  void dispose() {
    _downloadLimitCtrl.dispose();
    _uploadLimitCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final sync = context.watch<SyncService>();
    final isMobile = MediaQuery.of(context).size.width < 600;

    return Scaffold(
      backgroundColor: AppColors.grey98,
      body: ListView(
        padding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 24, vertical: isMobile ? 16 : 24),
        children: [
          const Text(
            'Settings',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              color: AppColors.heading,
            ),
          ),
          const SizedBox(height: 24),

          // ---- Account ----
          _SectionCard(
            title: 'Account',
            icon: Icons.person_outline,
            children: [
              _ReadOnlyField(
                label: 'Username',
                value: auth.username ?? 'Unknown',
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: ElevatedButton.icon(
                  onPressed: () => auth.logout(),
                  icon: const Icon(Icons.logout, size: 18),
                  label: const Text('Log Out'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.filePdf,
                    foregroundColor: AppColors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 10,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // ---- Sync Settings ----
          _SectionCard(
            title: 'Sync Settings',
            icon: Icons.sync,
            children: [
              // Sync folder path
              _ReadOnlyField(
                label: 'Sync Folder',
                value: sync.syncFolderPath != null ? sync.syncFolderPath!.split('/').last : 'Not configured',
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: () => _changeSyncFolder(sync),
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: const Text('Change Folder'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.green800,
                    side: const BorderSide(color: AppColors.green800),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Sync mode
              _DropdownField<bool>(
                label: 'Sync Mode',
                value: _periodicSync,
                items: const [
                  DropdownMenuItem(value: false, child: Text('Immediate (recommended)')),
                  DropdownMenuItem(value: true, child: Text('Periodic')),
                ],
                onChanged: (v) => setState(() => _periodicSync = v ?? false),
              ),

              // Sync interval (only if periodic)
              if (_periodicSync) ...[
                const SizedBox(height: 16),
                Text(
                  'Sync Interval: ${_syncIntervalSec.round()}s',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AppColors.heading,
                  ),
                ),
                Slider(
                  value: _syncIntervalSec,
                  min: 15,
                  max: 300,
                  divisions: 57,
                  activeColor: AppColors.green800,
                  inactiveColor: AppColors.grey91,
                  label: '${_syncIntervalSec.round()}s',
                  onChanged: (v) => setState(() => _syncIntervalSec = v),
                ),
                const Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('15s', style: TextStyle(fontSize: 11, color: AppColors.muted)),
                    Text('300s', style: TextStyle(fontSize: 11, color: AppColors.muted)),
                  ],
                ),
              ],

              const SizedBox(height: 16),

              // Conflict resolution
              _DropdownField<ConflictResolution>(
                label: 'Conflict Resolution',
                value: sync.conflictResolution,
                items: const [
                  DropdownMenuItem(
                    value: ConflictResolution.serverWins,
                    child: Text('Server wins'),
                  ),
                  DropdownMenuItem(
                    value: ConflictResolution.localWins,
                    child: Text('Local wins'),
                  ),
                  DropdownMenuItem(
                    value: ConflictResolution.newestWins,
                    child: Text('Newest wins (default)'),
                  ),
                ],
                onChanged: (v) {
                  if (v != null) sync.setConflictResolution(v);
                },
              ),
            ],
          ),

          const SizedBox(height: 16),

          // ---- Bandwidth ----
          _SectionCard(
            title: 'Bandwidth',
            icon: Icons.speed,
            children: [
              _InputField(
                label: 'Download Speed Limit (MB/s)',
                hint: '0 = unlimited',
                controller: _downloadLimitCtrl,
                onSubmitted: (_) => _applyBandwidth(sync),
              ),
              const SizedBox(height: 12),
              _InputField(
                label: 'Upload Speed Limit (MB/s)',
                hint: '0 = unlimited',
                controller: _uploadLimitCtrl,
                onSubmitted: (_) => _applyBandwidth(sync),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: ElevatedButton(
                  onPressed: () => _applyBandwidth(sync),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.green800,
                    foregroundColor: AppColors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 10,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: const Text('Apply'),
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // ---- Downloads ----
          _SectionCard(
            title: 'Downloads',
            icon: Icons.download,
            children: [
              _ReadOnlyField(
                label: 'Default Download Location',
                value: _defaultDownloadPath.isNotEmpty ? _defaultDownloadPath.split('/').last : 'Ask each time',
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: () async {
                      final result = await FilePicker.platform.getDirectoryPath(
                        dialogTitle: 'Choose default download location',
                      );
                      if (result != null) {
                        final prefs = await SharedPreferences.getInstance();
                        await prefs.setString('default_download_path', result);
                        setState(() => _defaultDownloadPath = result);
                      }
                    },
                    icon: const Icon(Icons.folder_open, size: 18),
                    label: const Text('Choose Folder'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.green800,
                      side: const BorderSide(color: AppColors.green800),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                  if (_defaultDownloadPath.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () async {
                        final prefs = await SharedPreferences.getInstance();
                        await prefs.remove('default_download_path');
                        setState(() => _defaultDownloadPath = '');
                      },
                      child: const Text('Clear', style: TextStyle(color: AppColors.filePdf, fontSize: 13)),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 4),
              const Text('Leave empty to ask each time', style: TextStyle(fontSize: 11, color: AppColors.muted)),
            ],
          ),

          const SizedBox(height: 16),

          // ---- About ----
          _SectionCard(
            title: 'About',
            icon: Icons.info_outline,
            children: [
              _ReadOnlyField(label: 'Version', value: '1.0.0'),
            ],
          ),

          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Future<void> _changeSyncFolder(SyncService sync) async {
    final result = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose a local folder to sync with CloudSpace',
    );
    if (result == null) return;
    await sync.setSyncFolder(result, remotePath: '/');
    if (sync.isEnabled) {
      sync.startSync();
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Sync folder set to: ${result.split('/').last}'),
          backgroundColor: AppColors.green700,
        ),
      );
    }
  }

  void _applyBandwidth(SyncService sync) {
    final dlMb = double.tryParse(_downloadLimitCtrl.text) ?? 0;
    final ulMb = double.tryParse(_uploadLimitCtrl.text) ?? 0;
    final dlBps = (dlMb * 1024 * 1024).round();
    final ulBps = (ulMb * 1024 * 1024).round();
    sync.setBandwidthLimits(downloadBps: dlBps, uploadBps: ulBps);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Bandwidth limits updated'),
        backgroundColor: AppColors.green700,
      ),
    );
  }

}

// ---------------------------------------------------------------------------
// Reusable widgets for the settings screen
// ---------------------------------------------------------------------------

class _SectionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<Widget> children;

  const _SectionCard({
    required this.title,
    required this.icon,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
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

class _ReadOnlyField extends StatelessWidget {
  final String label;
  final String value;

  const _ReadOnlyField({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: AppColors.body,
          ),
        ),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.grey96,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            value,
            style: const TextStyle(
              fontSize: 14,
              color: AppColors.heading,
            ),
            softWrap: true,
            overflow: TextOverflow.visible,
          ),
        ),
      ],
    );
  }
}

class _DropdownField<T> extends StatelessWidget {
  final String label;
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  const _DropdownField({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: AppColors.body,
          ),
        ),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: AppColors.grey96,
            borderRadius: BorderRadius.circular(8),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<T>(
              value: value,
              isExpanded: true,
              items: items,
              onChanged: onChanged,
              style: const TextStyle(fontSize: 14, color: AppColors.heading),
              dropdownColor: AppColors.white,
            ),
          ),
        ),
      ],
    );
  }
}

class _InputField extends StatelessWidget {
  final String label;
  final String hint;
  final TextEditingController controller;
  final ValueChanged<String>? onSubmitted;

  const _InputField({
    required this.label,
    required this.hint,
    required this.controller,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: AppColors.body,
          ),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[\d.]')),
          ],
          onSubmitted: onSubmitted,
          decoration: InputDecoration(
            hintText: hint,
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
          style: const TextStyle(fontSize: 14, color: AppColors.heading),
        ),
      ],
    );
  }
}
