// drive_sidebar.dart — navigation sidebar bound to DriveAccountManager.
// Adapted from the old AppSidebar; reads the active Drive account for the
// header and shows storage from DriveCache values passed in.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../config/theme.dart';
import '../services/drive/drive_account_manager.dart';

class DriveSidebarItem {
  final IconData icon;
  final String label;
  final String route;
  const DriveSidebarItem({required this.icon, required this.label, required this.route});
}

class DriveSidebar extends StatelessWidget {
  final String currentRoute;
  final int usedBytes;
  final int totalBytes;
  final VoidCallback onNewPressed;
  final ValueChanged<String> onNavigate;

  const DriveSidebar({
    super.key,
    required this.currentRoute,
    required this.usedBytes,
    required this.totalBytes,
    required this.onNewPressed,
    required this.onNavigate,
  });

  static const _items = [
    DriveSidebarItem(icon: Icons.home_outlined, label: 'Home', route: 'dashboard'),
    DriveSidebarItem(icon: Icons.folder_outlined, label: 'My Drive', route: 'files'),
    DriveSidebarItem(icon: Icons.people_outline, label: 'Shared with me', route: 'shared'),
    DriveSidebarItem(icon: Icons.access_time, label: 'Recent', route: 'recent'),
    DriveSidebarItem(icon: Icons.star_outline, label: 'Starred', route: 'starred'),
    DriveSidebarItem(icon: Icons.delete_outline, label: 'Trash', route: 'trash'),
    DriveSidebarItem(icon: Icons.history, label: 'Activity', route: 'activity'),
  ];

  String _fmt(int bytes) {
    final b = bytes.toDouble();
    if (b < 1024) return '${b.toInt()} B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final pct = totalBytes > 0 ? (usedBytes / totalBytes).clamp(0.0, 1.0) : 0.0;
    final topPad = MediaQuery.of(context).padding.top;

    return Container(
      width: 220,
      color: AppColors.white,
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.only(top: topPad + 16, left: 20, right: 20, bottom: 8),
            child: Row(children: [
              Image.asset('assets/logo.png', width: 40, height: 40),
              const SizedBox(width: 10),
              const Text('CloudSpace',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.green800)),
            ]),
          ),
          // Active account
          Consumer<DriveAccountManager>(
            builder: (context, mgr, _) {
              final a = mgr.activeAccount;
              if (a == null) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Row(children: [
                  CircleAvatar(
                    radius: 12,
                    backgroundColor: AppColors.green700,
                    child: Text(a.displayName.isNotEmpty ? a.displayName[0].toUpperCase() : 'U',
                        style: const TextStyle(color: AppColors.white, fontSize: 11, fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(a.displayName,
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppColors.heading),
                        overflow: TextOverflow.ellipsis),
                  ),
                  if (mgr.accounts.length > 1)
                    Text('${mgr.accounts.length}',
                        style: const TextStyle(fontSize: 10, color: AppColors.muted, fontWeight: FontWeight.w600)),
                ]),
              );
            },
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: onNewPressed,
                icon: const Icon(Icons.add, size: 20),
                label: const Text('New'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.green700,
                  foregroundColor: AppColors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: _items
                  .map((item) => _NavItem(
                        icon: item.icon,
                        label: item.label,
                        isActive: currentRoute == item.route,
                        onTap: () => onNavigate(item.route),
                      ))
                  .toList(),
            ),
          ),
          Padding(
            padding: EdgeInsets.only(left: 16, right: 16, top: 16, bottom: 16 + MediaQuery.of(context).padding.bottom),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.storage_outlined, size: 16, color: AppColors.body),
                  const SizedBox(width: 4),
                  const Text('STORAGE',
                      style: TextStyle(
                          fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.body, letterSpacing: 0.5)),
                  const Spacer(),
                  Text('${(pct * 100).toInt()}%',
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.green700)),
                ]),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: pct,
                    backgroundColor: AppColors.grey91,
                    valueColor: const AlwaysStoppedAnimation<Color>(AppColors.green700),
                    minHeight: 6,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                    totalBytes > 0
                        ? '${_fmt(usedBytes)} of ${_fmt(totalBytes)} used'
                        : '${_fmt(usedBytes)} used',
                    style: const TextStyle(fontSize: 11, color: AppColors.muted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;
  const _NavItem({required this.icon, required this.label, required this.isActive, required this.onTap});

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
          child: Row(children: [
            Icon(icon, size: 20, color: isActive ? AppColors.green800 : AppColors.body),
            const SizedBox(width: 12),
            Text(label,
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                    color: isActive ? AppColors.green800 : AppColors.body)),
          ]),
        ),
      ),
    );
  }
}
