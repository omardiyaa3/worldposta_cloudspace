// drive_cache.dart — cached Drive data for the UI, bound to ONE account.
//
// Replaces the old Nextcloud DataCacheService. A DriveCache wraps a single
// account's [DriveApi]; main.dart disposes and recreates it on account switch,
// so one account's cached data never bleeds into another's view (isolation).
//
// Two-phase load like the old cache: phase 1 (root + quota + recent) unblocks
// the dashboard; phase 2 (shared/starred/trash/activity) fills the rest.

import 'dart:async';
import 'package:flutter/foundation.dart';

import '../../models/drive_file.dart';
import 'drive_api.dart';

class DriveCache extends ChangeNotifier {
  final DriveApi api;
  Timer? _refreshTimer;

  DriveCache(this.api);

  // ── cached collections ──────────────────────────────────────────────────
  List<DriveFile> rootFiles = [];
  List<DriveFile> recentFiles = [];
  List<DriveFile> sharedWithMe = [];
  List<DriveFile> sharedByMe = [];
  List<DriveFile> starredFiles = [];
  List<DriveFile> trashFiles = [];
  DriveQuota? quota;
  List<DriveActivity> activityFeed = [];
  final List<Map<String, dynamic>> _localActivity = [];

  String quotaWarningLevel = 'ok'; // ok | warning | critical
  bool isFirstLoad = true;
  bool isRefreshing = false;
  bool _phase2Done = false;
  bool get isFullyLoaded => _phase2Done;

  // Per-parent folder cache, keyed by parentId ("root" for the drive root).
  final Map<String, List<DriveFile>> _folderCache = {};
  String _key(String? parentId) => parentId ?? 'root';

  Future<void> init() async {
    await _loadAll();
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) => _loadAll());
  }

  bool _fullRefreshRunning = false;

  Future<void> refresh() async {
    if (_fullRefreshRunning) return;
    _fullRefreshRunning = true;
    isRefreshing = true;
    notifyListeners();
    await _loadAll();
    isRefreshing = false;
    _fullRefreshRunning = false;
    notifyListeners();
  }

  Future<void> _loadAll() async {
    try {
      final phase1 = await Future.wait([
        api.listFiles(parentId: null),
        api.quota(),
        api.listRecent(),
      ]);
      rootFiles = phase1[0] as List<DriveFile>;
      quota = phase1[1] as DriveQuota;
      recentFiles = phase1[2] as List<DriveFile>;
      _folderCache['root'] = rootFiles;
      _updateQuotaWarning();

      isFirstLoad = false;
      _phase2Done = false;
      notifyListeners(); // dashboard can render

      final phase2 = await Future.wait([
        api.listSharedWithMe(),
        api.listSharedByMe(),
        api.listStarred(),
        api.listTrash(),
        api.myActivity(),
      ]);
      sharedWithMe = phase2[0] as List<DriveFile>;
      sharedByMe = phase2[1] as List<DriveFile>;
      starredFiles = phase2[2] as List<DriveFile>;
      trashFiles = phase2[3] as List<DriveFile>;
      activityFeed = phase2[4] as List<DriveActivity>;

      _phase2Done = true;
      notifyListeners();
    } catch (e) {
      debugPrint('DriveCache._loadAll error: $e');
      if (isFirstLoad) {
        isFirstLoad = false;
        notifyListeners();
      }
    }
  }

  void _updateQuotaWarning() {
    final q = quota;
    if (q == null || q.isUnlimited || q.limitBytes <= 0) {
      quotaWarningLevel = 'ok';
      return;
    }
    final ratio = q.usedBytes / q.limitBytes;
    quotaWarningLevel = ratio >= 0.9 ? 'critical' : ratio >= 0.8 ? 'warning' : 'ok';
  }

  // ── folder browsing ───────────────────────────────────────────────────────

  /// Return a folder's children, from cache if present (and refresh in the
  /// background), else fetch. [parentId] null → root.
  Future<List<DriveFile>> getFolder(String? parentId) async {
    final k = _key(parentId);
    if (_folderCache.containsKey(k)) {
      _refreshFolder(parentId); // background
      return _folderCache[k]!;
    }
    final files = await api.listFiles(parentId: parentId);
    _folderCache[k] = files;
    if (k == 'root') rootFiles = files;
    return files;
  }

  Future<void> _refreshFolder(String? parentId) async {
    try {
      final files = await api.listFiles(parentId: parentId);
      final k = _key(parentId);
      _folderCache[k] = files;
      if (k == 'root') rootFiles = files;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> refreshFolder(String? parentId) async {
    try {
      final files = await api.listFiles(parentId: parentId);
      _folderCache[_key(parentId)] = files;
      if (parentId == null) rootFiles = files;
    } catch (e) {
      debugPrint('refreshFolder error: $e');
    }
    notifyListeners();
  }

  void clearFolderCache(String? parentId) => _folderCache.remove(_key(parentId));

  Future<void> refreshQuota() async {
    try {
      quota = await api.quota();
      _updateQuotaWarning();
    } catch (e) {
      debugPrint('refreshQuota error: $e');
    }
    notifyListeners();
  }

  Future<void> refreshTrash() async {
    try {
      trashFiles = await api.listTrash();
    } catch (e) {
      debugPrint('refreshTrash error: $e');
    }
    notifyListeners();
  }

  Future<void> refreshShared() async {
    try {
      final r = await Future.wait([api.listSharedWithMe(), api.listSharedByMe()]);
      sharedWithMe = r[0];
      sharedByMe = r[1];
    } catch (e) {
      debugPrint('refreshShared error: $e');
    }
    notifyListeners();
  }

  Future<void> refreshStarred() async {
    try {
      starredFiles = await api.listStarred();
    } catch (e) {
      debugPrint('refreshStarred error: $e');
    }
    notifyListeners();
  }

  Future<void> refreshRecent() async {
    try {
      recentFiles = await api.listRecent();
    } catch (e) {
      debugPrint('refreshRecent error: $e');
    }
    notifyListeners();
  }

  // ── local activity (optimistic, merged with server feed) ──────────────────

  void logLocalActivity(String action, {String? resourceId}) {
    _localActivity.insert(0, {
      'action': action,
      'resource_id': resourceId,
      'occurred_at': DateTime.now().toUtc().toIso8601String(),
      'local': true,
    });
    notifyListeners();
  }

  List<DriveActivity> get mergedActivityFeed {
    final local = _localActivity.map((m) => DriveActivity(
          id: 'local-${m['occurred_at']}',
          action: m['action'] as String? ?? '',
          resourceId: m['resource_id'] as String?,
          outcome: 'success',
          occurredAt: DateTime.tryParse(m['occurred_at'] as String? ?? ''),
        ));
    final all = [...local, ...activityFeed];
    all.sort((a, b) => (b.occurredAt ?? DateTime(2000)).compareTo(a.occurredAt ?? DateTime(2000)));
    return all;
  }

  // Convenience for dashboard/sidebar storage widgets.
  int get usedBytes => quota?.usedBytes ?? 0;
  int get totalBytes => quota?.limitBytes ?? -1;

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }
}
