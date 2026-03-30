import 'package:flutter/material.dart';
import '../config/theme.dart';

class TopBar extends StatefulWidget {
  final String? displayName;
  final String? planLabel;
  final VoidCallback? onNotificationTap;
  final VoidCallback? onSettingsTap;
  final VoidCallback? onProfileTap;
  final ValueChanged<String>? onSearch;

  const TopBar({
    super.key,
    this.displayName,
    this.planLabel,
    this.onNotificationTap,
    this.onSettingsTap,
    this.onProfileTap,
    this.onSearch,
  });

  @override
  State<TopBar> createState() => _TopBarState();
}

class _TopBarState extends State<TopBar> {
  bool _searchExpanded = false;
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _clearSearch() {
    _searchController.clear();
    widget.onSearch?.call('');
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 600;

    final topPadding = MediaQuery.of(context).padding.top;

    return Container(
      padding: EdgeInsets.only(
        top: topPadding,
        left: isMobile ? 12 : 24,
        right: isMobile ? 12 : 24,
      ),
      decoration: const BoxDecoration(
        color: AppColors.white,
        border: Border(bottom: BorderSide(color: AppColors.grey91, width: 1)),
      ),
      child: SizedBox(
        height: 56,
        child: Row(
        children: [
          // Search bar — collapsible on mobile
          if (!isMobile)
            Expanded(
              child: Container(
                height: 40,
                constraints: const BoxConstraints(maxWidth: 480),
                child: TextField(
                  controller: _searchController,
                  onChanged: widget.onSearch,
                  decoration: InputDecoration(
                    hintText: 'Search in Drive...',
                    prefixIcon: const Icon(Icons.search, color: AppColors.muted, size: 20),
                    suffixIcon: ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _searchController,
                      builder: (_, value, __) => value.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.close, size: 18, color: AppColors.muted),
                              onPressed: _clearSearch,
                            )
                          : const SizedBox.shrink(),
                    ),
                    filled: true,
                    fillColor: AppColors.grey96,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 0),
                  ),
                  style: const TextStyle(fontSize: 14),
                ),
              ),
            )
          else if (_searchExpanded)
            Expanded(
              child: SizedBox(
                height: 36,
                child: TextField(
                  controller: _searchController,
                  autofocus: true,
                  onChanged: widget.onSearch,
                  decoration: InputDecoration(
                    hintText: 'Search...',
                    prefixIcon: const Icon(Icons.search, color: AppColors.muted, size: 18),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () {
                        _clearSearch();
                        setState(() => _searchExpanded = false);
                      },
                    ),
                    filled: true,
                    fillColor: AppColors.grey96,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 0),
                  ),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            )
          else ...[
            IconButton(
              icon: const Icon(Icons.search, color: AppColors.azure47),
              onPressed: () => setState(() => _searchExpanded = true),
            ),
            const Spacer(),
          ],

          SizedBox(width: isMobile ? 4 : 24),

          // Notification bell
          IconButton(
            onPressed: widget.onNotificationTap,
            icon: const Icon(Icons.notifications_outlined, color: AppColors.azure47),
            iconSize: isMobile ? 22 : 24,
            padding: isMobile ? const EdgeInsets.all(6) : const EdgeInsets.all(8),
            constraints: isMobile ? const BoxConstraints() : null,
          ),

          // Settings
          IconButton(
            onPressed: widget.onSettingsTap,
            icon: const Icon(Icons.settings_outlined, color: AppColors.azure47),
            iconSize: isMobile ? 22 : 24,
            padding: isMobile ? const EdgeInsets.all(6) : const EdgeInsets.all(8),
            constraints: isMobile ? const BoxConstraints() : null,
          ),

          SizedBox(width: isMobile ? 4 : 12),

          // User profile — on mobile only show avatar
          InkWell(
            onTap: widget.onProfileTap,
            borderRadius: BorderRadius.circular(8),
            child: Row(
              children: [
                if (!isMobile)
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        widget.displayName ?? 'User',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.heading,
                        ),
                      ),
                      if (widget.planLabel != null)
                        Text(
                          widget.planLabel!,
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.muted,
                          ),
                        ),
                    ],
                  ),
                if (!isMobile) const SizedBox(width: 8),
                CircleAvatar(
                  radius: isMobile ? 16 : 18,
                  backgroundColor: AppColors.green700,
                  child: Text(
                    (widget.displayName ?? 'U')[0].toUpperCase(),
                    style: TextStyle(
                      color: AppColors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: isMobile ? 13 : 16,
                    ),
                  ),
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
