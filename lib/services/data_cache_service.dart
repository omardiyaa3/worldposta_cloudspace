import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/nc_file.dart';
import 'auth_service.dart';
import 'webdav_service.dart';

class DataCacheService extends ChangeNotifier {
  final AuthService _auth;
  late final WebDavService _webdav;
  Timer? _refreshTimer;

  // Cached data
  List<NcFile> rootFiles = [];
  List<NcFile> recentFiles = [];
  List<NcFile> sharedWithMe = [];
  List<NcFile> sharedByMe = [];
  List<NcFile> starredFiles = [];
  List<NcFile> trashFiles = [];
  Map<String, dynamic> quota = {};
  List<Map<String, dynamic>> activityFeed = [];
  String quotaWarningLevel = 'ok';
  bool isFirstLoad = true;
  bool isRefreshing = false;

  // Per-path cache for browsing folders
  final Map<String, List<NcFile>> _folderCache = {};

  DataCacheService(this._auth) {
    _webdav = WebDavService(_auth);
  }

  Future<void> init() async {
    await _loadAll();
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) => _loadAll());
  }

  bool _fullRefreshRunning = false;

  Future<void> refresh() async {
    // Don't stack multiple full refreshes
    if (_fullRefreshRunning) return;
    _fullRefreshRunning = true;
    isRefreshing = true;
    notifyListeners();
    _folderCache.clear();
    await _loadAll();
    isRefreshing = false;
    _fullRefreshRunning = false;
    notifyListeners();
  }

  Future<void> _loadAll() async {
    try {
      final results = await Future.wait([
        _webdav.listFiles('/'),         // 0
        _webdav.getQuota(),             // 1
        _webdav.listRecent(),           // 2
        _webdav.listSharedWithMe(),     // 3
        _webdav.listSharedByMe(),       // 4
        _webdav.listFavorites(),        // 5
        _webdav.listTrash(),            // 6
        _webdav.getActivity(),          // 7
      ]);

      rootFiles = results[0] as List<NcFile>;
      quota = results[1] as Map<String, dynamic>;
      recentFiles = results[2] as List<NcFile>;
      sharedWithMe = results[3] as List<NcFile>;
      sharedByMe = results[4] as List<NcFile>;
      starredFiles = results[5] as List<NcFile>;
      trashFiles = results[6] as List<NcFile>;
      activityFeed = results[7] as List<Map<String, dynamic>>;

      // Compute quota warning level
      final used = (quota['used'] as int?) ?? 0;
      final total = (quota['total'] as int?) ?? -1;
      if (total > 0) {
        final ratio = used / total;
        if (ratio >= 0.9) {
          quotaWarningLevel = 'critical';
        } else if (ratio >= 0.8) {
          quotaWarningLevel = 'warning';
        } else {
          quotaWarningLevel = 'ok';
        }
      } else {
        quotaWarningLevel = 'ok';
      }

      // Also store root in folder cache
      _folderCache['/'] = rootFiles;

      isFirstLoad = false;
      notifyListeners();
    } catch (e) {
      debugPrint('DataCacheService._loadAll error: $e');
      // On first load failure, still mark as done so UI isn't stuck
      if (isFirstLoad) {
        isFirstLoad = false;
        notifyListeners();
      }
    }
  }

  Future<void> refreshFolder(String path) async {
    isRefreshing = true;
    notifyListeners();
    try {
      final files = await _webdav.listFiles(path);
      _folderCache[path] = files;
      if (path == '/') rootFiles = files;
    } catch (e) {
      debugPrint('refreshFolder error: $e');
    }
    isRefreshing = false;
    notifyListeners();
  }

  Future<void> refreshQuota() async {
    isRefreshing = true;
    notifyListeners();
    try {
      quota = await _webdav.getQuota();
      final used = (quota['used'] as int?) ?? 0;
      final total = (quota['total'] as int?) ?? -1;
      if (total > 0) {
        final ratio = used / total;
        quotaWarningLevel = ratio >= 0.9 ? 'critical' : ratio >= 0.8 ? 'warning' : 'ok';
      }
    } catch (e) {
      debugPrint('refreshQuota error: $e');
    }
    isRefreshing = false;
    notifyListeners();
  }

  Future<void> refreshTrash() async {
    isRefreshing = true;
    notifyListeners();
    try {
      trashFiles = await _webdav.listTrash();
    } catch (e) {
      debugPrint('refreshTrash error: $e');
    }
    isRefreshing = false;
    notifyListeners();
  }

  Future<void> refreshShared() async {
    isRefreshing = true;
    notifyListeners();
    try {
      final results = await Future.wait([
        _webdav.listSharedWithMe(),
        _webdav.listSharedByMe(),
      ]);
      sharedWithMe = results[0] as List<NcFile>;
      sharedByMe = results[1] as List<NcFile>;
    } catch (e) {
      debugPrint('refreshShared error: $e');
    }
    isRefreshing = false;
    notifyListeners();
  }

  Future<void> refreshStarred() async {
    try {
      starredFiles = await _webdav.listFavorites();
      notifyListeners();
    } catch (e) {
      debugPrint('refreshStarred error: $e');
    }
  }

  Future<void> refreshRecent() async {
    try {
      recentFiles = await _webdav.listRecent();
      notifyListeners();
    } catch (e) {
      debugPrint('refreshRecent error: $e');
    }
  }

  Future<List<NcFile>> getFolder(String path) async {
    if (_folderCache.containsKey(path)) {
      // Return cached data immediately, refresh in background
      _refreshFolder(path);
      return _folderCache[path]!;
    }
    // Not cached yet — fetch and cache
    final files = await _webdav.listFiles(path);
    _folderCache[path] = files;
    return files;
  }

  Future<void> _refreshFolder(String path) async {
    try {
      final files = await _webdav.listFiles(path);
      _folderCache[path] = files;
      if (path == '/') {
        rootFiles = files;
      }
      notifyListeners();
    } catch (_) {}
  }

  void clearFolderCache(String path) {
    _folderCache.remove(path);
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }
}
