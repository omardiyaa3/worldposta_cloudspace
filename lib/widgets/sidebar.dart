import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../config/theme.dart';
import '../services/account_manager.dart';

class SidebarItem {
  final IconData icon;
  final String label;
  final String route;

  const SidebarItem({
    required this.icon,
    required this.label,
    required this.route,
  });
}

class AppSidebar extends StatelessWidget {
  final String currentRoute;
  final double usedStorage;
  final double totalStorage;
  final VoidCallback onNewPressed;
  final ValueChanged<String> onNavigate;

  const AppSidebar({
    super.key,
    required this.currentRoute,
    required this.usedStorage,
    required this.totalStorage,
    required this.onNewPressed,
    required this.onNavigate,
  });

  static const _items = [
    SidebarItem(icon: Icons.dashboard_outlined, label: 'Dashboard', route: 'dashboard'),
    SidebarItem(icon: Icons.folder_outlined, label: 'My Files', route: 'files'),
    SidebarItem(icon: Icons.share_outlined, label: 'Shared', route: 'shared'),
    SidebarItem(icon: Icons.access_time, label: 'Recent', route: 'recent'),
    SidebarItem(icon: Icons.star_outline, label: 'Starred', route: 'starred'),
    SidebarItem(icon: Icons.delete_outline, label: 'Trash', route: 'trash'),
    SidebarItem(icon: Icons.history, label: 'Activity', route: 'activity'),
    SidebarItem(icon: Icons.chat_bubble_outline, label: 'Talk', route: 'talk'),
  ];

  @override
  Widget build(BuildContext context) {
    final storagePercent = totalStorage > 0 ? (usedStorage / totalStorage) : 0.0;

    final topPadding = MediaQuery.of(context).padding.top;

    return Container(
      width: 220,
      color: AppColors.white,
      child: Column(
        children: [
          // Logo
          Padding(
            padding: EdgeInsets.only(top: topPadding + 16, left: 20, right: 20, bottom: 8),
            child: Row(
              children: [
                Image.asset('assets/logo.png', width: 40, height: 40),
                const SizedBox(width: 10),
                const Text(
                  'CloudSpace',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppColors.green800,
                  ),
                ),
              ],
            ),
          ),

          // Active account indicator
          Builder(
            builder: (context) {
              final accountMgr = context.watch<AccountManager>();
              final active = accountMgr.activeAccount;
              if (active == null) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 12,
                      backgroundColor: AppColors.green700,
                      child: Text(
                        active.displayName.isNotEmpty ? active.displayName[0].toUpperCase() : 'U',
                        style: const TextStyle(color: AppColors.white, fontSize: 11, fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        active.displayName,
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppColors.heading),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (accountMgr.accounts.length > 1)
                      Text(
                        '${accountMgr.accounts.length}',
                        style: const TextStyle(fontSize: 10, color: AppColors.muted, fontWeight: FontWeight.w600),
                      ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 4),

          // + New Button
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: onNewPressed,
                icon: const Icon(Icons.add, size: 20),
                label: const Text('New'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.green800,
                  foregroundColor: AppColors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Nav Items
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: _items.map((item) {
                final isActive = currentRoute == item.route;
                return _NavItem(
                  icon: item.icon,
                  label: item.label,
                  isActive: isActive,
                  onTap: () => onNavigate(item.route),
                );
              }).toList(),
            ),
          ),

          // Storage indicator
          Padding(
            padding: EdgeInsets.only(left: 16, right: 16, top: 16, bottom: 16 + MediaQuery.of(context).padding.bottom),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.storage_outlined, size: 16, color: AppColors.body),
                    const SizedBox(width: 4),
                    const Text(
                      'STORAGE',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppColors.body,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${(storagePercent * 100).toInt()}%',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppColors.green700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: storagePercent,
                    backgroundColor: AppColors.grey91,
                    valueColor: const AlwaysStoppedAnimation<Color>(AppColors.green800),
                    minHeight: 6,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${_formatSize(usedStorage)} of ${_formatSize(totalStorage)} used',
                  style: const TextStyle(fontSize: 11, color: AppColors.muted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
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

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: isActive ? AppColors.greenActiveBg : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: isActive ? AppColors.green800 : AppColors.body,
              ),
              const SizedBox(width: 12),
              Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                  color: isActive ? AppColors.green800 : AppColors.body,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
