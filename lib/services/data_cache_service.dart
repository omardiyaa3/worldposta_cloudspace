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
  // Per-path ETags — used to skip re-fetching unchanged folders
  final Map<String, String> _folderEtags = {};

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
    // Don't clear folder cache — visited folders stay cached for instant navigation
    // _loadAll updates root files and the root cache entry automatically
    await _loadAll();
    isRefreshing = false;
    _fullRefreshRunning = false;
    notifyListeners();
  }

  Future<void> _loadAll() async {
    try {
      // Phase 1: quota + root files — enough to show dashboard immediately
      final phase1 = await Future.wait([
        _webdav.listFiles('/'),
        _webdav.getQuota(),
      ]);

      rootFiles = phase1[0] as List<NcFile>;
      quota = phase1[1] as Map<String, dynamic>;
      _folderCache['/'] = rootFiles;
      _updateQuotaWarning();

      isFirstLoad = false;
      notifyListeners(); // Dashboard can render now

      // Phase 2: everything else in background
      final phase2 = await Future.wait([
        _webdav.listRecent(),
        _webdav.listSharedWithMe(),
        _webdav.listSharedByMe(),
        _webdav.listFavorites(),
        _webdav.listTrash(),
        _webdav.getActivity(),
      ]);

      recentFiles = phase2[0] as List<NcFile>;
      sharedWithMe = phase2[1] as List<NcFile>;
      sharedByMe = phase2[2] as List<NcFile>;
      starredFiles = phase2[3] as List<NcFile>;
      trashFiles = phase2[4] as List<NcFile>;
      activityFeed = phase2[5] as List<Map<String, dynamic>>;

      notifyListeners(); // Other tabs can render now
    } catch (e) {
      debugPrint('DataCacheService._loadAll error: $e');
      if (isFirstLoad) {
        isFirstLoad = false;
        notifyListeners();
      }
    }
  }

  void _updateQuotaWarning() {
    final used = (quota['used'] as int?) ?? 0;
    final total = (quota['total'] as int?) ?? -1;
    if (total > 0) {
      final ratio = used / total;
      quotaWarningLevel = ratio >= 0.9 ? 'critical' : ratio >= 0.8 ? 'warning' : 'ok';
    } else {
      quotaWarningLevel = 'ok';
    }
  }

  Future<void> refreshFolder(String path) async {
    isRefreshing = true;
    notifyListeners();
    try {
      // Always fetch fresh when user explicitly hits refresh
      final files = await _webdav.listFiles(path);
      _folderCache[path] = files;
      if (path == '/') rootFiles = files;
      // Update stored ETag
      final etag = await _webdav.getFolderEtag(path);
      if (etag != null) _folderEtags[path] = etag;
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
      _updateQuotaWarning();
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
      // Return cached data immediately, check for changes in background
      _refreshFolderIfChanged(path);
      return _folderCache[path]!;
    }
    // Not cached — fetch, cache, store ETag
    final files = await _webdav.listFiles(path);
    _folderCache[path] = files;
    // Store the folder's ETag for future change detection
    _webdav.getFolderEtag(path).then((etag) {
      if (etag != null) _folderEtags[path] = etag;
    });
    return files;
  }

  /// Only re-fetch if the folder's ETag changed on the server
  Future<void> _refreshFolderIfChanged(String path) async {
    try {
      final serverEtag = await _webdav.getFolderEtag(path);
      if (serverEtag == null) return;

      final cachedEtag = _folderEtags[path];
      if (cachedEtag == serverEtag) {
        // Nothing changed — skip the full fetch
        return;
      }

      // ETag changed — fetch new contents
      final files = await _webdav.listFiles(path);
      _folderCache[path] = files;
      _folderEtags[path] = serverEtag;
      if (path == '/') rootFiles = files;
      notifyListeners();
    } catch (_) {}
  }

  void clearFolderCache(String path) {
    _folderCache.remove(path);
    _folderEtags.remove(path);
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }
}
