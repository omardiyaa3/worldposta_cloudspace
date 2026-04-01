import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../config/theme.dart';
import '../../models/nc_file.dart';
import '../../services/auth_service.dart';
import '../../services/data_cache_service.dart';
import '../../widgets/file_type_badge.dart';
import '../files/file_preview_screen.dart';

class DashboardScreen extends StatefulWidget {
  final VoidCallback onNavigateToFiles;

  const DashboardScreen({super.key, required this.onNavigateToFiles});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final cache = context.watch<DataCacheService>();

    // Show loading while cache fetches data for the first time
    if (cache.isFirstLoad) {
      return const Center(child: CircularProgressIndicator(color: AppColors.green700));
    }

    // Derive dashboard data from cache
    final allFiles = cache.rootFiles;
    final recentFiles = cache.recentFiles.where((f) => !f.isDirectory).take(6).toList();
    final quota = cache.quota;
    final sharedCount = cache.sharedWithMe.length;
    final totalFiles = allFiles.where((f) => !f.isDirectory).length;
    final totalFolders = allFiles.where((f) => f.isDirectory).length;

    // Calculate storage by category — only from root files to avoid double counting
    int imgSize = 0, vidSize = 0, docSize = 0, otherSize = 0;
    for (final f in allFiles) {
      if (f.isDirectory) continue;
      final ext = f.extension.toLowerCase();
      final ct = f.contentType?.toLowerCase() ?? '';
      if (_isImage(ext, ct)) {
        imgSize += f.size;
      } else if (_isVideo(ext, ct)) {
        vidSize += f.size;
      } else if (_isDocument(ext, ct)) {
        docSize += f.size;
      } else {
        otherSize += f.size;
      }
    }
    // Add folder sizes to "other" since we can't categorize folder contents
    for (final f in allFiles) {
      if (f.isDirectory) otherSize += f.size;
    }
    // Cap total categories to not exceed used space
    final categorizedTotal = imgSize + vidSize + docSize + otherSize;
    final usedBytes = (quota['used'] as int?) ?? 0;
    if (categorizedTotal > usedBytes && usedBytes > 0) {
      // Scale down proportionally
      final scale = usedBytes / categorizedTotal;
      imgSize = (imgSize * scale).round();
      vidSize = (vidSize * scale).round();
      docSize = (docSize * scale).round();
      otherSize = usedBytes - imgSize - vidSize - docSize;
    }

    final used = (quota['used'] as int?) ?? 0;
    final total = (quota['total'] as int?) ?? -1;

    final isMobile = MediaQuery.of(context).size.width < 600;

    return RefreshIndicator(
      onRefresh: cache.refresh,
      child: cache.isFirstLoad
          ? const Center(child: CircularProgressIndicator(color: AppColors.green700))
          : ListView(
              padding: EdgeInsets.all(isMobile ? 16 : 24),
              children: [
                // Quota warning banner
                if (cache.quotaWarningLevel == 'warning' || cache.quotaWarningLevel == 'critical')
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 16),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: cache.quotaWarningLevel == 'critical'
                          ? AppColors.filePdf.withValues(alpha: 0.12)
                          : AppColors.fileAi.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: cache.quotaWarningLevel == 'critical'
                            ? AppColors.filePdf.withValues(alpha: 0.4)
                            : AppColors.fileAi.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.warning_amber_rounded,
                          size: 20,
                          color: cache.quotaWarningLevel == 'critical'
                              ? AppColors.filePdf
                              : AppColors.fileAi,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            cache.quotaWarningLevel == 'critical'
                                ? 'Storage almost full (${total > 0 ? ((used / total) * 100).toInt() : 0}% used)! Free up space.'
                                : 'Storage is running low (${total > 0 ? ((used / total) * 100).toInt() : 0}% used)',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: cache.quotaWarningLevel == 'critical'
                                  ? AppColors.filePdf
                                  : AppColors.fileAi,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                // Welcome banner
                Container(
                  padding: EdgeInsets.all(isMobile ? 14 : 20),
                  decoration: BoxDecoration(
                    color: AppColors.azure17,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: isMobile
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(18),
                                  child: Image.asset('assets/logo.png', width: 36, height: 36),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    'Experience the new WorldPosta Drive',
                                    style: const TextStyle(
                                      color: AppColors.white,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 14,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Your cloud storage, secured and simplified.',
                              style: TextStyle(
                                color: AppColors.white.withValues(alpha: 0.7),
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 10),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton(
                                onPressed: () => launchUrl(
                                  Uri.parse('https://worldposta.com/cloudspace'),
                                  mode: LaunchMode.externalApplication,
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.green700,
                                ),
                                child: const Text('Learn More'),
                              ),
                            ),
                          ],
                        )
                      : Row(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(22),
                              child: Image.asset('assets/logo.png', width: 44, height: 44),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Experience the new WorldPosta Drive',
                                    style: TextStyle(
                                      color: AppColors.white,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 15,
                                    ),
                                  ),
                                  Text(
                                    'Your cloud storage, secured and simplified.',
                                    style: TextStyle(
                                      color: AppColors.white.withValues(alpha: 0.7),
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            ElevatedButton(
                              onPressed: () => launchUrl(
                                Uri.parse('https://worldposta.com/cloudspace'),
                                mode: LaunchMode.externalApplication,
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.green700,
                              ),
                              child: const Text('Learn More'),
                            ),
                          ],
                        ),
                ),

                const SizedBox(height: 24),

                // Overview header
                Text(
                  'Overview',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: AppColors.heading,
                  ),
                ),
                Text(
                  'Welcome back, ${auth.displayName ?? 'User'}. Your cloud ecosystem is looking healthy.',
                  style: const TextStyle(fontSize: 14, color: AppColors.body),
                ),

                const SizedBox(height: 20),

                // Stats cards
                _buildStatsRow(used, total, totalFiles, totalFolders, sharedCount),

                const SizedBox(height: 24),

                // Recent files + Storage analytics
                LayoutBuilder(
                  builder: (context, constraints) {
                    if (constraints.maxWidth > 700) {
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(flex: 2, child: _buildRecentFiles(recentFiles)),
                          const SizedBox(width: 16),
                          Expanded(child: _buildStorageAnalytics(used, total, imgSize, vidSize, docSize, otherSize)),
                        ],
                      );
                    }
                    return Column(
                      children: [
                        _buildRecentFiles(recentFiles),
                        const SizedBox(height: 16),
                        _buildStorageAnalytics(used, total, imgSize, vidSize, docSize, otherSize),
                      ],
                    );
                  },
                ),
              ],
            ),
    );
  }

  Widget _buildStatsRow(int used, int total, int totalFiles, int totalFolders, int sharedCount) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobile = constraints.maxWidth < 500;
        final cardWidth = isMobile
            ? (constraints.maxWidth - 16) / 2
            : (constraints.maxWidth - 48) / 4;
        return Wrap(
          spacing: isMobile ? 12 : 16,
          runSpacing: isMobile ? 12 : 16,
          children: [
            _StatCard(
              label: 'Total Files',
              value: '$totalFiles',
              subtitle: '$totalFolders folders',
              width: cardWidth.clamp(140.0, 260.0),
              compact: isMobile,
            ),
            _StatCard(
              label: 'Storage Used',
              value: _formatSize(used.toDouble()),
              subtitle: total > 0
                  ? '${((used / total) * 100).toInt()}% of ${_formatSize(total.toDouble())}'
                  : 'Unlimited',
              width: cardWidth.clamp(140.0, 260.0),
              compact: isMobile,
            ),
            _StatCard(
              label: 'Shared Files',
              value: '$sharedCount',
              subtitle: '',
              width: cardWidth.clamp(140.0, 260.0),
              compact: isMobile,
            ),
            _StatCard(
              label: 'Team Members',
              value: '--',
              subtitle: '',
              width: cardWidth.clamp(140.0, 260.0),
              compact: isMobile,
            ),
          ],
        );
      },
    );
  }

  Widget _buildRecentFiles(List<NcFile> recentFiles) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.grey91),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'Recent Files',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.heading,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: widget.onNavigateToFiles,
                child: const Text(
                  'View All',
                  style: TextStyle(color: AppColors.green700, fontSize: 13),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (recentFiles.isEmpty)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Center(
                child: Text(
                  'No files yet. Upload your first file!',
                  style: TextStyle(color: AppColors.muted),
                ),
              ),
            )
          else
            ...recentFiles.take(3).map((file) => _RecentFileRow(file: file)),
        ],
      ),
    );
  }

  Widget _buildStorageAnalytics(int used, int total, int imagesSize, int videosSize, int documentsSize, int otherSize) {
    final usedGb = used / (1024 * 1024 * 1024);
    final totalGb = total > 0 ? total / (1024 * 1024 * 1024) : 0.0;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.grey91),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Storage Analytics',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppColors.heading,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Text(
                'TOTAL USED',
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.muted,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                total > 0
                    ? '${usedGb.toStringAsFixed(1)} GB / ${totalGb.toStringAsFixed(0)} GB'
                    : '${usedGb.toStringAsFixed(1)} GB',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.heading,
                ),
              ),
            ],
          ),
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
          _StorageCategory(color: AppColors.green700, label: 'Documents', value: _formatSize(documentsSize.toDouble())),
          _StorageCategory(color: AppColors.filePsd, label: 'Images', value: _formatSize(imagesSize.toDouble())),
          _StorageCategory(color: AppColors.filePng, label: 'Videos', value: _formatSize(videosSize.toDouble())),
          _StorageCategory(color: AppColors.fileHtml, label: 'Other', value: _formatSize(otherSize.toDouble())),
        ],
      ),
    );
  }

  static bool _isImage(String ext, String ct) {
    return ct.startsWith('image/') ||
        const {'png', 'jpg', 'jpeg', 'gif', 'webp', 'svg', 'bmp', 'ico', 'tiff', 'psd', 'ai'}.contains(ext);
  }

  static bool _isVideo(String ext, String ct) {
    return ct.startsWith('video/') ||
        const {'mp4', 'mov', 'avi', 'mkv', 'wmv', 'flv', 'webm', 'm4v', 'mpg', 'mpeg'}.contains(ext);
  }

  static bool _isDocument(String ext, String ct) {
    return ct.startsWith('text/') ||
        ct.contains('pdf') ||
        ct.contains('document') ||
        ct.contains('spreadsheet') ||
        ct.contains('presentation') ||
        const {
          'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt', 'rtf', 'csv',
          'odt', 'ods', 'odp', 'md', 'html', 'htm', 'xml', 'json', 'yaml', 'yml',
        }.contains(ext);
  }

  String _formatSize(double bytes) {
    if (bytes < 1024) return '${bytes.toInt()} B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final String subtitle;
  final double width;
  final bool compact;

  const _StatCard({
    required this.label,
    required this.value,
    required this.subtitle,
    required this.width,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      padding: EdgeInsets.all(compact ? 12 : 20),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.grey91),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: compact ? 11 : 13, color: AppColors.body)),
          SizedBox(height: compact ? 4 : 8),
          Text(
            value,
            style: TextStyle(
              fontSize: compact ? 20 : 28,
              fontWeight: FontWeight.w700,
              color: AppColors.heading,
            ),
            overflow: TextOverflow.ellipsis,
          ),
          if (subtitle.isNotEmpty)
            Text(
              subtitle,
              style: TextStyle(fontSize: compact ? 10 : 12, color: AppColors.green700),
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }
}

class _RecentFileRow extends StatelessWidget {
  final NcFile file;

  const _RecentFileRow({required this.file});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => FilePreviewScreen(file: file),
          ),
        );
      },
      child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          FileTypeBadge(extension: file.extension, size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  file.name,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: AppColors.heading,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '${file.lastModified != null ? DateFormat('MMM d, y').format(file.lastModified!) : ''} ${file.sizeFormatted}',
                  style: const TextStyle(fontSize: 12, color: AppColors.muted),
                ),
              ],
            ),
          ),
        ],
      ),
      ),
    );
  }
}

class _StorageCategory extends StatelessWidget {
  final Color color;
  final String label;
  final String value;

  const _StorageCategory({
    required this.color,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(fontSize: 13, color: AppColors.body)),
          const Spacer(),
          Text(
            value,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.heading,
            ),
          ),
        ],
      ),
    );
  }
}
