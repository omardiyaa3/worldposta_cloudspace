import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../config/theme.dart';
import '../services/sync_service.dart';

class SyncMonitorScreen extends StatelessWidget {
  const SyncMonitorScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<SyncService>(
      builder: (context, sync, _) {
        return Scaffold(
          backgroundColor: AppColors.grey98,
          appBar: AppBar(
            title: const Text(
              'Sync Monitor',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            backgroundColor: AppColors.white,
            foregroundColor: AppColors.heading,
            elevation: 0,
            actions: [
              if (sync.isSyncing)
                IconButton(
                  icon: const Icon(Icons.stop_circle_outlined, color: AppColors.filePdf),
                  tooltip: 'Stop Sync',
                  onPressed: () => sync.stopSync(),
                )
              else
                IconButton(
                  icon: const Icon(Icons.play_circle_outline, color: AppColors.green700),
                  tooltip: 'Sync Now',
                  onPressed: sync.syncFolderPath != null
                      ? () {
                          if (!sync.isEnabled) sync.startSync();
                          sync.syncNow();
                        }
                      : null,
                ),
            ],
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Status card
                _buildCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            sync.isSyncing ? Icons.sync : Icons.cloud_done,
                            color: sync.isSyncing ? AppColors.green700 : AppColors.azure65,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              sync.status,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: AppColors.heading,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (sync.syncFolderPath != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          sync.syncFolderPath!.split('/').last,
                          style: const TextStyle(fontSize: 12, color: AppColors.body),
                        ),
                      ],
                      if (sync.isSyncing && sync.estimatedTimeRemaining != '--') ...[
                        const SizedBox(height: 8),
                        Text(
                          'ETA: ${sync.estimatedTimeRemaining}',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: AppColors.green800,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // File progress
                _buildCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'File Progress',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.heading,
                        ),
                      ),
                      const SizedBox(height: 8),
                      _buildProgressRow(
                        label: '${sync.filesProcessed} / ${sync.totalFilesToSync} files',
                        value: sync.totalFilesToSync > 0
                            ? sync.filesProcessed / sync.totalFilesToSync
                            : 0,
                        color: AppColors.green700,
                      ),
                      const SizedBox(height: 12),
                      _buildProgressRow(
                        label:
                            '${_formatBytes(sync.totalBytesProcessed)} / ${_formatBytes(sync.totalBytesToSync)}',
                        value: sync.totalBytesToSync > 0
                            ? sync.totalBytesProcessed / sync.totalBytesToSync
                            : 0,
                        color: AppColors.azure47,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // Current file
                if (sync.isSyncing && sync.currentFile.isNotEmpty)
                  _buildCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Current File',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppColors.heading,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          sync.currentFile,
                          style: const TextStyle(
                            fontSize: 13,
                            fontFamily: 'monospace',
                            color: AppColors.body,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 8),
                        _buildProgressRow(
                          label:
                              '${_formatBytes(sync.currentFileBytes)} / ${_formatBytes(sync.currentFileTotalBytes)}',
                          value: sync.currentFileTotalBytes > 0
                              ? sync.currentFileBytes / sync.currentFileTotalBytes
                              : 0,
                          color: AppColors.green600,
                        ),
                      ],
                    ),
                  ),
                if (sync.isSyncing && sync.currentFile.isNotEmpty) const SizedBox(height: 12),

                // Stats
                _buildCard(
                  child: Row(
                    children: [
                      _buildStatChip(Icons.download, '${sync.lastDownloaded}', 'Down', AppColors.green700),
                      const SizedBox(width: 16),
                      _buildStatChip(Icons.upload, '${sync.lastUploaded}', 'Up', AppColors.azure47),
                      const SizedBox(width: 16),
                      _buildStatChip(Icons.error_outline, '${sync.lastErrors}', 'Errors', AppColors.filePdf),
                      const SizedBox(width: 16),
                      _buildStatChip(Icons.warning_amber, '${sync.lastConflicts}', 'Conflicts', AppColors.away),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // Sync log
                _buildCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Sync Log',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.heading,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        height: 300,
                        decoration: BoxDecoration(
                          color: AppColors.grey96,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: sync.log.isEmpty
                            ? const Center(
                                child: Text(
                                  'No log entries yet.',
                                  style: TextStyle(color: AppColors.muted, fontSize: 13),
                                ),
                              )
                            : ListView.builder(
                                padding: const EdgeInsets.all(8),
                                itemCount: sync.log.length,
                                itemBuilder: (_, i) => Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 1),
                                  child: Text(
                                    sync.log[i],
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontFamily: 'monospace',
                                      color: sync.log[i].contains('ERROR') || sync.log[i].contains('FAIL')
                                          ? AppColors.filePdf
                                          : sync.log[i].contains('DOWNLOAD') || sync.log[i].contains('UPLOAD')
                                              ? AppColors.green800
                                              : AppColors.body,
                                    ),
                                  ),
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // Action buttons
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: sync.syncFolderPath != null
                            ? () {
                                if (!sync.isEnabled) sync.startSync();
                                sync.syncNow();
                              }
                            : null,
                        icon: const Icon(Icons.sync, size: 18),
                        label: const Text('Sync Now'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.green800,
                          foregroundColor: AppColors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: sync.isEnabled ? () => sync.stopSync() : null,
                        icon: const Icon(Icons.stop, size: 18),
                        label: const Text('Stop Sync'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.filePdf,
                          side: const BorderSide(color: AppColors.filePdf),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildCard({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.grey91),
      ),
      child: child,
    );
  }

  Widget _buildProgressRow({
    required String label,
    required double value,
    required Color color,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: value.clamp(0.0, 1.0),
            backgroundColor: AppColors.grey91,
            color: color,
            minHeight: 6,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: AppColors.body),
        ),
      ],
    );
  }

  Widget _buildStatChip(IconData icon, String value, String label, Color color) {
    return Expanded(
      child: Column(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: color),
          ),
          Text(
            label,
            style: const TextStyle(fontSize: 10, color: AppColors.body),
          ),
        ],
      ),
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
