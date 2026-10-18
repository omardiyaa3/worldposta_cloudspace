// notification_bell.dart — the web's notifications bell: unread count, the
// latest notifications, mark one / all read. Polls every minute while the app
// is in the foreground (there are no push notifications).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../config/theme.dart';
import '../services/drive/drive_api.dart';
import '../services/drive/drive_client.dart';

class DriveNotificationBell extends StatefulWidget {
  final DriveApi api;
  /// Opens the file a notification is about (null → just mark it read).
  final void Function(String fileId)? onOpenFile;
  final Duration pollEvery;
  const DriveNotificationBell({super.key, required this.api, this.onOpenFile, this.pollEvery = const Duration(seconds: 60)});

  @override
  State<DriveNotificationBell> createState() => _DriveNotificationBellState();
}

class _DriveNotificationBellState extends State<DriveNotificationBell> with WidgetsBindingObserver {
  List<DriveNotification> _items = [];
  int _unread = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _poll();
    _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  void _start() {
    _timer?.cancel();
    _timer = Timer.periodic(widget.pollEvery, (_) => _poll());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _poll();
      _start();
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _timer?.cancel();
    }
  }

  Future<void> _poll() async {
    try {
      final r = await widget.api.notifications();
      if (!mounted) return;
      setState(() {
        _items = r.items;
        _unread = r.unread;
      });
    } catch (_) {/* offline / transient: keep the last state */}
  }

  Future<void> _markRead(DriveNotification n) async {
    if (n.read) return;
    setState(() {
      _items = [for (final x in _items) x.id == n.id ? x.markedRead() : x];
      if (_unread > 0) _unread--;
    });
    try {
      await widget.api.markNotificationRead(n.id);
    } catch (_) {}
  }

  Future<void> _markAll() async {
    setState(() {
      _items = [for (final x in _items) x.markedRead()];
      _unread = 0;
    });
    try {
      await widget.api.markAllNotificationsRead();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e)), backgroundColor: AppColors.filePdf));
      }
      _poll();
    }
  }

  void _show() {
    _poll();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
        Future<void> all() async {
          await _markAll();
          setS(() {});
        }

        return SafeArea(
          child: SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.6,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
                child: Row(children: [
                  const Icon(Icons.notifications_none, color: AppColors.green800, size: 20),
                  const SizedBox(width: 8),
                  const Expanded(
                      child: Text('Notifications', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.heading))),
                  if (_unread > 0) TextButton(onPressed: all, child: const Text('Mark all read')),
                ]),
              ),
              const Divider(height: 1),
              Expanded(
                child: _items.isEmpty
                    ? const Center(child: Text('You’re all caught up.', style: TextStyle(color: AppColors.muted)))
                    : ListView.separated(
                        itemCount: _items.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final n = _items[i];
                          return ListTile(
                            leading: Icon(_icon(n.kind), color: n.read ? AppColors.muted : AppColors.green700),
                            title: Text(n.title,
                                style: TextStyle(fontSize: 14, fontWeight: n.read ? FontWeight.w400 : FontWeight.w600, color: AppColors.heading)),
                            subtitle: Text(
                              [if (n.body.isNotEmpty) n.body, if (n.createdAt != null) DateFormat('MMM d, HH:mm').format(n.createdAt!.toLocal())]
                                  .join('\n'),
                              style: const TextStyle(fontSize: 12, color: AppColors.muted),
                            ),
                            isThreeLine: n.body.isNotEmpty,
                            trailing: n.read ? null : const CircleAvatar(radius: 4, backgroundColor: AppColors.green700),
                            onTap: () {
                              _markRead(n);
                              setS(() {});
                              final id = n.resourceId;
                              if (id != null && widget.onOpenFile != null) {
                                Navigator.pop(ctx);
                                widget.onOpenFile!(id);
                              }
                            },
                          );
                        },
                      ),
              ),
            ]),
          ),
        );
      }),
    );
  }

  static IconData _icon(String kind) {
    if (kind.contains('share') || kind.contains('grant')) return Icons.person_add_alt;
    if (kind.contains('comment') || kind.contains('mention')) return Icons.comment_outlined;
    if (kind.contains('approval')) return Icons.fact_check_outlined;
    if (kind.contains('access')) return Icons.lock_open;
    return Icons.notifications_none;
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 600;
    return IconButton(
      tooltip: 'Notifications',
      onPressed: _show,
      iconSize: isMobile ? 22 : 24,
      padding: isMobile ? const EdgeInsets.all(6) : const EdgeInsets.all(8),
      constraints: isMobile ? const BoxConstraints() : null,
      icon: Badge(
        isLabelVisible: _unread > 0,
        label: Text(_unread > 99 ? '99+' : '$_unread'),
        backgroundColor: AppColors.filePdf,
        child: const Icon(Icons.notifications_none, color: AppColors.azure47),
      ),
    );
  }
}
