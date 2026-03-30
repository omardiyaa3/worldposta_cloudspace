import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'auth_service.dart';
import 'webdav_service.dart';
import '../models/nc_file.dart';

// ---------------------------------------------------------------------------
// Conflict resolution strategy when both local and remote changed since last
// sync. Stored in SharedPreferences as its name string.
// ---------------------------------------------------------------------------
enum ConflictResolution { serverWins, localWins, newestWins }

// ---------------------------------------------------------------------------
// Sync mode: immediate (file watcher + fallback timer) or periodic (timer only).
// ---------------------------------------------------------------------------
enum SyncMode { immediate, periodic }

// ---------------------------------------------------------------------------
// A single entry in the sync journal, representing the last-known synced state
// of one file.
// ---------------------------------------------------------------------------
class _JournalEntry {
  /// The ETag the server returned when we last synced this file.
  final String? etag;

  /// The file size on the server at last sync.
  final int size;

  /// The local file's mtime (millisSinceEpoch) right after the last download
  /// or right before the last upload.  We compare the current local mtime to
  /// this value to detect local edits.
  final int localMtimeMs;

  /// The server's lastModified (millisSinceEpoch) at last sync.
  final int remoteModifiedMs;

  _JournalEntry({
    required this.etag,
    required this.size,
    required this.localMtimeMs,
    required this.remoteModifiedMs,
  });

  Map<String, dynamic> toJson() => {
        'etag': etag,
        'size': size,
        'localMtimeMs': localMtimeMs,
        'remoteModifiedMs': remoteModifiedMs,
      };

  factory _JournalEntry.fromJson(Map<String, dynamic> j) => _JournalEntry(
        etag: j['etag'] as String?,
        size: (j['size'] as num?)?.toInt() ?? 0,
        localMtimeMs: (j['localMtimeMs'] as num?)?.toInt() ?? 0,
        remoteModifiedMs: (j['remoteModifiedMs'] as num?)?.toInt() ?? 0,
      );
}

// ---------------------------------------------------------------------------
// SyncService — full two-way Nextcloud file sync with journal, retry, resume,
// and configurable conflict resolution.
// ---------------------------------------------------------------------------
class SyncService extends ChangeNotifier {
  final AuthService _auth;
  late final WebDavService _webdav;

  Timer? _syncTimer;
  String? _syncFolderPath;
  String _remoteSyncPath = '/';
  bool _isSyncing = false;
  bool _isEnabled = false;
  bool _shouldStop = false;
  String _status = 'Not syncing';
  DateTime? _lastSync;
  final int _syncIntervalSeconds = 30;
  int _lastDownloaded = 0;
  int _lastUploaded = 0;
  int _lastConflicts = 0;
  int _lastErrors = 0;
  final List<String> _log = [];

  // ---- Real-time progress tracking fields ---------------------------------
  int totalFilesToSync = 0;
  int filesProcessed = 0;
  String currentFile = '';
  int currentFileBytes = 0;
  int currentFileTotalBytes = 0;
  int totalBytesToSync = 0;
  int totalBytesProcessed = 0;
  DateTime? syncStartTime;

  String get estimatedTimeRemaining {
    if (syncStartTime == null || totalBytesProcessed == 0) return '--';
    final elapsed = DateTime.now().difference(syncStartTime!).inSeconds;
    if (elapsed == 0) return 'Calculating...';
    final bytesPerSec = totalBytesProcessed / elapsed;
    final remaining = totalBytesToSync - totalBytesProcessed;
    if (remaining <= 0) return 'Almost done...';
    final secsLeft = (remaining / bytesPerSec).round();
    if (secsLeft < 60) return '${secsLeft}s';
    if (secsLeft < 3600) return '${secsLeft ~/ 60}m ${secsLeft % 60}s';
    return '${secsLeft ~/ 3600}h ${(secsLeft % 3600) ~/ 60}m';
  }

  /// Files that failed during the last sync cycle — retried next cycle.
  Set<String> _failedFiles = {};

  /// File system watcher subscription for immediate sync mode.
  StreamSubscription<FileSystemEvent>? _watcherSubscription;

  /// Debounce timer for file watcher events.
  Timer? _watcherDebounceTimer;

  /// Current sync mode.
  SyncMode _syncMode = SyncMode.immediate;

  /// How many times to retry a failed file operation before giving up.
  static const int _maxRetries = 3;

  /// Delay between retries (doubles each attempt).
  static const Duration _retryBaseDelay = Duration(seconds: 2);

  /// Maximum bytes/sec for downloads. 0 = unlimited.
  int _downloadBytesPerSec = 0;

  /// Maximum bytes/sec for uploads. 0 = unlimited.
  int _uploadBytesPerSec = 0;

  /// How to resolve conflicts when both sides changed.
  ConflictResolution _conflictResolution = ConflictResolution.newestWins;

  /// In-memory journal: remotePath -> _JournalEntry
  Map<String, _JournalEntry> _journal = {};

  // ---- Public getters (preserves existing API) ----------------------------

  bool get isSyncing => _isSyncing;
  bool get isEnabled => _isEnabled;
  String get status => _status;
  DateTime? get lastSync => _lastSync;
  String? get syncFolderPath => _syncFolderPath;
  String get remoteSyncPath => _remoteSyncPath;
  List<String> get log => List.unmodifiable(_log);

  int get lastDownloaded => _lastDownloaded;
  int get lastUploaded => _lastUploaded;
  int get lastConflicts => _lastConflicts;
  int get lastErrors => _lastErrors;

  ConflictResolution get conflictResolution => _conflictResolution;
  int get downloadBytesPerSec => _downloadBytesPerSec;
  int get uploadBytesPerSec => _uploadBytesPerSec;
  SyncMode get syncMode => _syncMode;
  Set<String> get failedFiles => Set.unmodifiable(_failedFiles);

  // ---- Constructor --------------------------------------------------------

  SyncService(this._auth) {
    _webdav = WebDavService(_auth);
  }

  // ---- Logging ------------------------------------------------------------

  void _log2(String msg) {
    debugPrint('[SYNC] $msg');
    _log.add(msg);
    if (_log.length > 200) _log.removeAt(0);
  }

  // ---- Initialisation & preferences ---------------------------------------

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _syncFolderPath = prefs.getString('sync_folder_path');
    _remoteSyncPath = prefs.getString('sync_remote_path') ?? '/';
    _isEnabled = prefs.getBool('sync_enabled') ?? false;
    _downloadBytesPerSec = prefs.getInt('sync_dl_bps') ?? 0;
    _uploadBytesPerSec = prefs.getInt('sync_ul_bps') ?? 0;

    final crName = prefs.getString('sync_conflict_resolution');
    _conflictResolution = ConflictResolution.values.firstWhere(
      (e) => e.name == crName,
      orElse: () => ConflictResolution.newestWins,
    );

    final smName = prefs.getString('sync_mode');
    _syncMode = SyncMode.values.firstWhere(
      (e) => e.name == smName,
      orElse: () => SyncMode.immediate,
    );

    // Restore failed files from previous session.
    final failedList = prefs.getStringList('sync_failed_files');
    if (failedList != null) {
      _failedFiles = failedList.toSet();
    }

    if (_syncFolderPath != null) {
      await _loadJournal();
    }

    if (_isEnabled && _syncFolderPath != null) {
      startSync();
    }
    notifyListeners();
  }

  Future<void> setSyncFolder(String localPath,
      {String remotePath = '/'}) async {
    _syncFolderPath = localPath;
    _remoteSyncPath = remotePath;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('sync_folder_path', localPath);
    await prefs.setString('sync_remote_path', remotePath);

    final dir = Directory(localPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    // Load (or create) the journal for this folder.
    await _loadJournal();

    notifyListeners();
  }

  Future<void> setConflictResolution(ConflictResolution cr) async {
    _conflictResolution = cr;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('sync_conflict_resolution', cr.name);
    notifyListeners();
  }

  Future<void> setBandwidthLimits({int? downloadBps, int? uploadBps}) async {
    if (downloadBps != null) _downloadBytesPerSec = downloadBps;
    if (uploadBps != null) _uploadBytesPerSec = uploadBps;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('sync_dl_bps', _downloadBytesPerSec);
    await prefs.setInt('sync_ul_bps', _uploadBytesPerSec);
    notifyListeners();
  }

  Future<void> setSyncMode(SyncMode mode) async {
    _syncMode = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('sync_mode', mode.name);

    // If sync is active, restart to apply the new mode.
    if (_isEnabled && _syncFolderPath != null) {
      stopSync();
      startSync();
    }
    notifyListeners();
  }

  // ---- Journal persistence ------------------------------------------------

  /// Journal file path: stored next to the sync folder as a hidden file.
  String get _journalPath {
    // Place the journal file inside the sync folder itself (hidden dot-file).
    return '${_syncFolderPath!}${Platform.pathSeparator}.cloudspace_sync.json';
  }

  Future<void> _loadJournal() async {
    try {
      final file = File(_journalPath);
      if (await file.exists()) {
        final raw = await file.readAsString();
        final Map<String, dynamic> decoded = jsonDecode(raw);
        _journal = decoded.map(
          (k, v) => MapEntry(k, _JournalEntry.fromJson(v as Map<String, dynamic>)),
        );
        _log2('Journal loaded: ${_journal.length} entries');
      } else {
        _journal = {};
        _log2('No journal file found — starting fresh');
      }
    } catch (e) {
      _log2('Failed to load journal, starting fresh: $e');
      _journal = {};
    }
  }

  Future<void> _saveJournal() async {
    try {
      final file = File(_journalPath);
      final encoded = jsonEncode(
        _journal.map((k, v) => MapEntry(k, v.toJson())),
      );
      await file.writeAsString(encoded);
    } catch (e) {
      _log2('Failed to save journal: $e');
    }
  }

  // ---- Start / Stop / SyncNow (public API) --------------------------------

  void startSync() {
    _isEnabled = true;
    _shouldStop = false;
    _saveEnabled(true);
    _status = 'Watching for changes...';
    notifyListeners();
    _runSync();

    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(
        Duration(seconds: _syncIntervalSeconds), (_) => _runSync());

    // Start file watcher if in immediate mode.
    if (_syncMode == SyncMode.immediate && _syncFolderPath != null) {
      _startFileWatcher();
    }
  }

  void stopSync() {
    _syncTimer?.cancel();
    _syncTimer = null;
    _stopFileWatcher();
    _shouldStop = true;
    _isEnabled = false;
    _isSyncing = false;
    _status = 'Sync stopped';
    _saveEnabled(false);
    notifyListeners();
  }

  Future<void> syncNow() async => await _runSync();

  // ---- Main sync loop ------------------------------------------------------

  Future<void> _runSync() async {
    if (_isSyncing || _syncFolderPath == null) {
      _log2('Skipping: isSyncing=$_isSyncing syncFolder=$_syncFolderPath');
      return;
    }

    _shouldStop = false;
    _isSyncing = true;
    _lastDownloaded = 0;
    _lastUploaded = 0;
    _lastConflicts = 0;
    _lastErrors = 0;
    totalFilesToSync = 0;
    filesProcessed = 0;
    currentFile = '';
    currentFileBytes = 0;
    currentFileTotalBytes = 0;
    totalBytesToSync = 0;
    totalBytesProcessed = 0;
    syncStartTime = DateTime.now();
    _log.clear();
    _status = 'Syncing...';
    notifyListeners();

    try {
      // Reload journal from disk at start of every sync to ensure consistency
      await _loadJournal();
      _log2('Starting sync: local=$_syncFolderPath remote=$_remoteSyncPath (journal: ${_journal.length} entries)');

      // Verify local folder exists and is accessible
      final localDir = Directory(_syncFolderPath!);
      if (!await localDir.exists()) {
        _log2('Local folder does not exist, creating: $_syncFolderPath');
        await localDir.create(recursive: true);
      }

      // Test: can we list the local folder?
      try {
        final localCount = await localDir.list().length;
        _log2('Local folder has $localCount items');
      } catch (e) {
        _log2('ERROR: Cannot read local folder: $e');
        _status = 'Error: Cannot access local folder (sandbox?)';
        _isSyncing = false;
        notifyListeners();
        return;
      }

      // Test: can we list remote?
      try {
        final remoteFiles = await _webdav.listFiles(_remoteSyncPath);
        _log2('Remote has ${remoteFiles.length} items');
      } catch (e) {
        _log2('ERROR: Cannot list remote: $e');
        _status = 'Error: Cannot access server';
        _isSyncing = false;
        notifyListeners();
        return;
      }

      // Log any previously failed files that will be retried this cycle.
      if (_failedFiles.isNotEmpty) {
        _log2('Retrying ${_failedFiles.length} previously failed files');
      }

      if (_shouldStop) {
        _log2('Sync aborted by user');
        _isSyncing = false;
        _status = 'Sync stopped';
        notifyListeners();
        return;
      }

      await _syncDirectory(_syncFolderPath!, _remoteSyncPath);

      if (_shouldStop) {
        _log2('Sync aborted by user during directory sync');
        _isSyncing = false;
        _status = 'Sync stopped';
        notifyListeners();
        return;
      }

      // Persist journal and failed files after full sync pass.
      await _saveJournal();
      await _saveFailedFiles();

      _lastSync = DateTime.now();
      final parts = <String>[];
      if (_lastDownloaded > 0) parts.add('$_lastDownloaded down');
      if (_lastUploaded > 0) parts.add('$_lastUploaded up');
      if (_lastConflicts > 0) parts.add('$_lastConflicts conflicts');
      if (_lastErrors > 0) parts.add('$_lastErrors errors');
      if (parts.isEmpty) {
        _status = 'Up to date (${_log.length} checks)';
      } else {
        _status = 'Synced: ${parts.join(', ')}';
      }
      _log2(
          'Sync complete: $_lastDownloaded down, $_lastUploaded up, $_lastConflicts conflicts, $_lastErrors errors');
    } catch (e, stack) {
      _log2('SYNC ERROR: $e\n$stack');
      _status = 'Error: ${e.toString().split('\n').first}';
    }

    _isSyncing = false;
    notifyListeners();
  }

  // ---- Directory sync (recursive) -----------------------------------------

  Future<void> _syncDirectory(String localPath, String remotePath) async {
    if (_shouldStop) return;
    _log2('--- Syncing dir: local=$localPath remote=$remotePath');

    final localDir = Directory(localPath);
    if (!await localDir.exists()) {
      await localDir.create(recursive: true);
    }

    // Get remote listing
    List<NcFile> remoteItems;
    try {
      remoteItems = await _webdav.listFiles(remotePath);
      _log2('Remote items in $remotePath: ${remoteItems.length}');
      for (final r in remoteItems) {
        _log2('  remote: ${r.name} (dir=${r.isDirectory}, size=${r.size}, etag=${r.etag})');
      }
    } catch (e) {
      _log2('Cannot list remote $remotePath: $e — trying to create it');
      try {
        await _webdav.createDirectory(remotePath);
        remoteItems = [];
      } catch (e2) {
        _log2('Cannot create remote dir either: $e2');
        return;
      }
    }

    // Build remote lookup by name
    final remoteByName = <String, NcFile>{};
    for (final rf in remoteItems) {
      remoteByName[rf.name] = rf;
    }

    // Get local listing
    final localByName = <String, FileSystemEntity>{};
    try {
      await for (final entity in localDir.list(recursive: false)) {
        final name = entity.path.split(Platform.pathSeparator).last;
        // Skip hidden files (but don't skip the journal itself — it just won't
        // match any remote entry so it stays local-only).
        if (name.startsWith('.')) continue;
        localByName[name] = entity;
      }
    } catch (e) {
      _log2('Cannot list local $localPath: $e');
      return;
    }
    _log2('Local items in $localPath: ${localByName.length}');
    for (final name in localByName.keys) {
      _log2(
          '  local: $name (${localByName[name] is Directory ? 'dir' : 'file'})');
    }

    // Track which remote-paths we've visited so we can prune journal later.
    final visitedRemotePaths = <String>{};

    // ---- Process remote items ----
    for (final remote in remoteItems) {
      if (_shouldStop) return;
      final localEntity = localByName[remote.name];

      if (remote.isDirectory) {
        final subLocal =
            '$localPath${Platform.pathSeparator}${remote.name}';
        final subRemote = _joinRemote(remotePath, remote.name);
        await _syncDirectory(subLocal, subRemote);
        localByName.remove(remote.name);
        continue;
      }

      // It's a file.
      final fileRemotePath = remote.path; // e.g. /Documents/foo.txt
      visitedRemotePaths.add(fileRemotePath);

      final journalEntry = _journal[fileRemotePath];
      final localFile =
          (localEntity != null && localEntity is File) ? localEntity : null;

      if (journalEntry == null) {
        // ---- Not in journal: new file on one side or the other ----
        if (localFile == null) {
          // Only on server -> download
          _log2('NEW DOWNLOAD: ${remote.name} (not in journal, not local, ${_formatSize(remote.size)})');
          final destPath =
              '$localPath${Platform.pathSeparator}${remote.name}';
          totalFilesToSync++;
          totalBytesToSync += remote.size;
          currentFile = remote.name;
          currentFileBytes = 0;
          currentFileTotalBytes = remote.size;
          notifyListeners();
          await _retryOperation(
              'download ${remote.name}',
              () => _downloadWithResume(remote.path, destPath, remote.size));
          totalBytesProcessed += remote.size;
          currentFileBytes = remote.size;
          filesProcessed++;
          notifyListeners();
          await _recordJournalAfterDownload(fileRemotePath, destPath, remote);
          _lastDownloaded++;
        } else {
          // Both exist on server and locally but no journal entry.
          // Compare sizes: if same, assume in sync (likely just downloaded).
          // If different, use conflict resolution to decide.
          final localSize = await localFile.length();
          if (localSize == remote.size) {
            // Same size — assume in sync, just record in journal
            _log2('BASELINE: ${remote.name} — both exist, same size (${_formatSize(localSize)}), recording in journal');
            await _recordJournalAfterDownload(fileRemotePath, localFile.path, remote);
          } else {
            // Different sizes — conflict on first sync, use resolution strategy
            final localMod = await localFile.lastModified();
            final remoteMod = remote.lastModified ?? DateTime(2000);
            _log2('FIRST SYNC CONFLICT: ${remote.name} — local=${_formatSize(localSize)} remote=${_formatSize(remote.size)}');

            totalFilesToSync++;
            currentFile = remote.name;
            currentFileBytes = 0;
            notifyListeners();
            if (_conflictResolution == ConflictResolution.localWins ||
                (_conflictResolution == ConflictResolution.newestWins && localMod.isAfter(remoteMod))) {
              _log2('  -> Uploading local version');
              currentFileTotalBytes = localSize;
              totalBytesToSync += localSize;
              await _retryOperation('upload ${remote.name}',
                  () => _uploadFile(localFile.path, remote.path));
              totalBytesProcessed += localSize;
              await _recordJournalAfterUpload(fileRemotePath, localFile, remote);
              _lastUploaded++;
            } else {
              _log2('  -> Downloading server version');
              currentFileTotalBytes = remote.size;
              totalBytesToSync += remote.size;
              final destPath = '$localPath${Platform.pathSeparator}${remote.name}';
              await _retryOperation('download ${remote.name}',
                  () => _downloadWithResume(remote.path, destPath, remote.size));
              totalBytesProcessed += remote.size;
              await _recordJournalAfterDownload(fileRemotePath, destPath, remote);
              _lastDownloaded++;
            }
            filesProcessed++;
            notifyListeners();
            _lastConflicts++;
          }
        }
      } else {
        // ---- In journal: compare etag (remote) and mtime/size (local) ----
        final remoteChanged = _remoteChanged(remote, journalEntry);
        final localChanged =
            localFile != null && await _localChanged(localFile, journalEntry);

        _log2('COMPARE: ${remote.name} remoteChanged=$remoteChanged localChanged=$localChanged');

        if (remoteChanged && localChanged) {
          // ---- CONFLICT ----
          _lastConflicts++;
          totalFilesToSync++;
          currentFile = remote.name;
          currentFileBytes = 0;
          currentFileTotalBytes = remote.size;
          totalBytesToSync += remote.size;
          notifyListeners();
          _log2('  CONFLICT: ${remote.name} — both sides changed');
          await _resolveConflict(
            remote: remote,
            localFile: localFile,
            localPath: localPath,
            journalEntry: journalEntry,
          );
          totalBytesProcessed += remote.size;
          filesProcessed++;
          notifyListeners();
        } else if (remoteChanged) {
          // Server changed, local didn't (or local file deleted).
          final destPath =
              '$localPath${Platform.pathSeparator}${remote.name}';
          totalFilesToSync++;
          totalBytesToSync += remote.size;
          currentFile = remote.name;
          currentFileBytes = 0;
          currentFileTotalBytes = remote.size;
          notifyListeners();
          _log2('  -> Remote changed (etag), downloading');
          await _retryOperation(
              'download ${remote.name}',
              () => _downloadWithResume(remote.path, destPath, remote.size));
          totalBytesProcessed += remote.size;
          filesProcessed++;
          notifyListeners();
          await _recordJournalAfterDownload(fileRemotePath, destPath, remote);
          _lastDownloaded++;
        } else if (localChanged) {
          // Local changed, server didn't.
          totalFilesToSync++;
          currentFile = remote.name;
          currentFileBytes = 0;
          currentFileTotalBytes = remote.size;
          totalBytesToSync += remote.size;
          notifyListeners();
          _log2('  -> Local changed, uploading');
          await _retryOperation('upload ${remote.name}',
              () => _uploadFile(localFile.path, remote.path));
          totalBytesProcessed += remote.size;
          filesProcessed++;
          notifyListeners();
          await _recordJournalAfterUpload(
              fileRemotePath, localFile, remote);
          _lastUploaded++;
        } else if (localFile == null) {
          // Local file was deleted since last sync but remote unchanged ->
          // re-download (server wins for deletions — user should delete via
          // app, not filesystem, to propagate).
          totalFilesToSync++;
          totalBytesToSync += remote.size;
          currentFile = remote.name;
          currentFileBytes = 0;
          currentFileTotalBytes = remote.size;
          notifyListeners();
          _log2('  -> Local deleted, re-downloading from server');
          final destPath =
              '$localPath${Platform.pathSeparator}${remote.name}';
          await _retryOperation(
              'download ${remote.name}',
              () => _downloadWithResume(remote.path, destPath, remote.size));
          totalBytesProcessed += remote.size;
          filesProcessed++;
          notifyListeners();
          await _recordJournalAfterDownload(fileRemotePath, destPath, remote);
          _lastDownloaded++;
        } else {
          _log2('  -> In sync');
        }
      }
      localByName.remove(remote.name);
    }

    // ---- UPLOAD: local items not on remote ----
    for (final entry in localByName.entries) {
      if (_shouldStop) return;
      final name = entry.key;
      final entity = entry.value;
      final remoteItemPath = _joinRemote(remotePath, name);

      if (entity is Directory) {
        _log2('UPLOAD DIR: $name -> $remoteItemPath');
        try {
          await _webdav.createDirectory(remoteItemPath);
          _log2('  Created remote dir: $remoteItemPath');
        } catch (e) {
          _log2('  Remote dir create (may already exist): $e');
        }
        await _syncDirectory(entity.path, remoteItemPath);
      } else if (entity is File) {
        // Check journal: if it was in journal before but is now gone from
        // server, the server-side was deleted.  Respect that (don't re-upload).
        final existingJournal = _journal[remoteItemPath];
        if (existingJournal != null) {
          // Was synced before, server no longer has it -> server deleted it.
          _log2('SERVER DELETED: $name — removing local copy');
          try {
            await entity.delete();
          } catch (e) {
            _log2('  FAIL deleting local: $e');
          }
          _journal.remove(remoteItemPath);
          continue;
        }

        final fileSize = await entity.length();
        totalFilesToSync++;
        totalBytesToSync += fileSize;
        currentFile = name;
        currentFileBytes = 0;
        currentFileTotalBytes = fileSize;
        notifyListeners();
        _log2(
            'UPLOAD FILE: $name -> $remoteItemPath (${_formatSize(fileSize)})');
        await _retryOperation('upload $name',
            () => _uploadFile(entity.path, remoteItemPath));
        totalBytesProcessed += fileSize;
        filesProcessed++;
        notifyListeners();

        // Record in journal. We don't have the server's etag yet (would need
        // a PROPFIND after upload), so mark etag as null — next sync the
        // PROPFIND will populate it and since local won't have changed, it
        // will just update the journal.
        try {
          final stat = await entity.lastModified();
          _journal[remoteItemPath] = _JournalEntry(
            etag: null,
            size: fileSize,
            localMtimeMs: stat.millisecondsSinceEpoch,
            remoteModifiedMs: DateTime.now().millisecondsSinceEpoch,
          );
        } catch (_) {}
        _lastUploaded++;
      }
    }
  }

  // ---- Change detection helpers -------------------------------------------

  /// Returns true if the server's etag or size differs from the journal.
  bool _remoteChanged(NcFile remote, _JournalEntry journal) {
    // If journal etag is null (first upload, etag unknown), fall back to
    // comparing remote lastModified.
    if (journal.etag == null) {
      final remoteMod = remote.lastModified?.millisecondsSinceEpoch ?? 0;
      // Allow 2-second tolerance.
      return (remoteMod - journal.remoteModifiedMs).abs() > 2000 ||
          remote.size != journal.size;
    }
    return remote.etag != journal.etag;
  }

  /// Returns true if the local file's mtime or size differs from journal.
  Future<bool> _localChanged(File localFile, _JournalEntry journal) async {
    try {
      final stat = await localFile.lastModified();
      final size = await localFile.length();
      // Allow 1-second tolerance on mtime for filesystem granularity.
      final mtimeDiff =
          (stat.millisecondsSinceEpoch - journal.localMtimeMs).abs();
      return mtimeDiff > 1000 || size != journal.size;
    } catch (_) {
      return false;
    }
  }

  // ---- Conflict resolution ------------------------------------------------

  Future<void> _resolveConflict({
    required NcFile remote,
    required File localFile,
    required String localPath,
    required _JournalEntry journalEntry,
  }) async {
    switch (_conflictResolution) {
      case ConflictResolution.serverWins:
        _log2('  Conflict resolution: server wins — downloading');
        await _retryOperation(
            'download ${remote.name}',
            () => _downloadWithResume(
                remote.path, localFile.path, remote.size));
        await _recordJournalAfterDownload(
            remote.path, localFile.path, remote);
        _lastDownloaded++;
        break;

      case ConflictResolution.localWins:
        _log2('  Conflict resolution: local wins — uploading');
        await _retryOperation('upload ${remote.name}',
            () => _uploadFile(localFile.path, remote.path));
        await _recordJournalAfterUpload(remote.path, localFile, remote);
        _lastUploaded++;
        break;

      case ConflictResolution.newestWins:
        final localMod = await localFile.lastModified();
        final remoteMod = remote.lastModified ?? DateTime(2000);
        if (remoteMod.isAfter(localMod)) {
          _log2('  Conflict resolution: newest wins — remote is newer, downloading');
          await _retryOperation(
              'download ${remote.name}',
              () => _downloadWithResume(
                  remote.path, localFile.path, remote.size));
          await _recordJournalAfterDownload(
              remote.path, localFile.path, remote);
          _lastDownloaded++;
        } else {
          _log2('  Conflict resolution: newest wins — local is newer, uploading');
          await _retryOperation('upload ${remote.name}',
              () => _uploadFile(localFile.path, remote.path));
          await _recordJournalAfterUpload(remote.path, localFile, remote);
          _lastUploaded++;
        }
        break;
    }
  }

  // ---- Journal recording helpers ------------------------------------------

  Future<void> _recordJournalAfterDownload(
      String remotePath, String localPath, NcFile remote) async {
    try {
      final localFile = File(localPath);
      final localMod = await localFile.lastModified();
      _journal[remotePath] = _JournalEntry(
        etag: remote.etag,
        size: remote.size,
        localMtimeMs: localMod.millisecondsSinceEpoch,
        remoteModifiedMs:
            remote.lastModified?.millisecondsSinceEpoch ?? DateTime.now().millisecondsSinceEpoch,
      );
      // Save journal incrementally so progress isn't lost on interruption
      await _saveJournal();
    } catch (e) {
      _log2('  Warning: could not record journal after download: $e');
    }
  }

  Future<void> _recordJournalAfterUpload(
      String remotePath, File localFile, NcFile remote) async {
    try {
      final localMod = await localFile.lastModified();
      final localSize = await localFile.length();
      _journal[remotePath] = _JournalEntry(
        // After upload the server's etag changed; we don't know the new one.
        // Setting to null means the next sync will see remote "changed" (etag
        // mismatch) but local will also match (mtime/size same as journal) so
        // it'll be detected as remote-only change — but the downloaded file
        // will be identical, which is fine.  Alternatively we could do a
        // PROPFIND after upload, but that's expensive.  Mark etag null so next
        // sync does a lightweight re-check.
        etag: null,
        size: localSize,
        localMtimeMs: localMod.millisecondsSinceEpoch,
        remoteModifiedMs: DateTime.now().millisecondsSinceEpoch,
      );
      await _saveJournal();
    } catch (e) {
      _log2('  Warning: could not record journal after upload: $e');
    }
  }

  // ---- Retry wrapper ------------------------------------------------------

  /// Retry an async operation up to [_maxRetries] times with exponential
  /// back-off.  Logs each failure.
  Future<void> _retryOperation(
      String label, Future<void> Function() operation,
      {String? filePath}) async {
    for (int attempt = 1; attempt <= _maxRetries; attempt++) {
      try {
        await operation();
        if (filePath != null) _clearFailedFile(filePath);
        return; // success
      } catch (e) {
        _log2('  ATTEMPT $attempt/$_maxRetries FAILED ($label): $e');
        if (attempt == _maxRetries) {
          _log2('  GIVING UP on $label after $_maxRetries attempts');
          _lastErrors++;
          if (filePath != null) _recordFailedFile(filePath);
          return;
        }
        final delay = _retryBaseDelay * pow(2, attempt - 1);
        await Future.delayed(delay);
      }
    }
  }

  // ---- Download with resume support ----------------------------------------

  /// Download a file using HTTP Range header if a partial file already exists
  /// on disk (resume support).  Falls back to full download if the server does
  /// not support Range (HTTP 200 instead of 206).
  Future<void> _downloadWithResume(
      String remotePath, String localPath, int expectedSize) async {
    final file = File(localPath);
    int existingBytes = 0;

    // Check for a partial download (.part file).
    final partPath = '$localPath.part';
    final partFile = File(partPath);
    if (await partFile.exists()) {
      existingBytes = await partFile.length();
      if (existingBytes >= expectedSize) {
        // Already have the full file in the .part — just rename.
        existingBytes = 0; // start fresh to be safe
        await partFile.delete();
      }
    }

    // Build request with optional Range header.
    final url = _buildDownloadUri(remotePath);
    final request = http.Request('GET', url);
    request.headers.addAll(_authHeaders);
    if (existingBytes > 0) {
      request.headers['Range'] = 'bytes=$existingBytes-';
      _log2('  Resuming download from byte $existingBytes');
    }

    final streamedResponse = await request.send();

    IOSink sink;
    if (streamedResponse.statusCode == 206 && existingBytes > 0) {
      // Server supports resume — append to .part file.
      sink = partFile.openWrite(mode: FileMode.append);
    } else if (streamedResponse.statusCode == 200) {
      // Full download (server didn't support range, or fresh download).
      sink = partFile.openWrite(mode: FileMode.write);
    } else {
      throw Exception('Download failed: ${streamedResponse.statusCode}');
    }

    try {
      if (_downloadBytesPerSec > 0) {
        await _throttledPipe(streamedResponse.stream, sink, _downloadBytesPerSec);
      } else {
        await streamedResponse.stream.pipe(sink);
      }
    } finally {
      await sink.close();
    }

    // Rename .part -> final file.
    if (await file.exists()) {
      await file.delete();
    }
    await partFile.rename(localPath);
  }

  // ---- Upload with optional throttle --------------------------------------

  Future<void> _uploadFile(String localPath, String remotePath) async {
    if (_uploadBytesPerSec > 0) {
      await _uploadThrottled(localPath, remotePath);
    } else {
      await _webdav.uploadFileChunked(localPath, remotePath);
    }
  }

  Future<void> _uploadThrottled(String localPath, String remotePath) async {
    final file = File(localPath);
    final length = await file.length();
    final url = _buildDownloadUri(remotePath);

    final request = http.StreamedRequest('PUT', url);
    request.headers.addAll(_authHeaders);
    request.headers['Content-Type'] = 'application/octet-stream';
    request.contentLength = length;

    // Feed the stream with throttling.
    () async {
      try {
        final stream = file.openRead();
        int bytesSent = 0;
        final stopwatch = Stopwatch()..start();

        await for (final chunk in stream) {
          request.sink.add(chunk);
          bytesSent += chunk.length;

          // Throttle: if we've exceeded the rate, pause.
          if (_uploadBytesPerSec > 0) {
            final elapsed = stopwatch.elapsedMilliseconds;
            final expectedMs = (bytesSent / _uploadBytesPerSec * 1000).round();
            if (expectedMs > elapsed) {
              await Future.delayed(
                  Duration(milliseconds: expectedMs - elapsed));
            }
          }
        }
        await request.sink.close();
      } catch (e) {
        request.sink.addError(e);
        await request.sink.close();
      }
    }();

    final response = await request.send();
    if (response.statusCode != 201 &&
        response.statusCode != 204 &&
        response.statusCode != 200) {
      throw Exception('Upload failed: ${response.statusCode}');
    }
  }

  // ---- Throttled stream pipe -----------------------------------------------

  /// Pipe a byte stream to a sink while enforcing a maximum throughput.
  Future<void> _throttledPipe(
      Stream<List<int>> source, IOSink sink, int maxBytesPerSec) async {
    int totalBytes = 0;
    final stopwatch = Stopwatch()..start();

    await for (final chunk in source) {
      sink.add(chunk);
      totalBytes += chunk.length;

      final elapsed = stopwatch.elapsedMilliseconds;
      final expectedMs = (totalBytes / maxBytesPerSec * 1000).round();
      if (expectedMs > elapsed) {
        await Future.delayed(Duration(milliseconds: expectedMs - elapsed));
      }
    }
  }

  // ---- WebDav URI / header helpers (reuse _webdav internals via auth) ------

  /// Build a download/upload URI.  We replicate the URI building logic here
  /// because _webdav's _buildUri is private.  We use the same approach.
  Uri _buildDownloadUri(String remotePath) {
    final serverUri = Uri.parse(_auth.serverUrl!);
    // Construct WebDAV path: /remote.php/dav/files/<user><remotePath>
    final basePath = '/remote.php/dav/files/${_auth.userId}';
    final fullPath = '$basePath$remotePath';
    final segments =
        fullPath.split('/').where((s) => s.isNotEmpty).toList();
    return serverUri.replace(pathSegments: segments);
  }

  Map<String, String> get _authHeaders => {
        'Authorization': _auth.basicAuth,
        'OCS-APIRequest': 'true',
      };

  // ---- Utility -------------------------------------------------------------

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  String _joinRemote(String base, String name) {
    if (base.endsWith('/')) return '$base$name';
    return '$base/$name';
  }

  Future<void> _saveEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('sync_enabled', enabled);
  }

  // ---- Failed files persistence -------------------------------------------

  Future<void> _saveFailedFiles() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('sync_failed_files', _failedFiles.toList());
  }

  void _recordFailedFile(String path) {
    _failedFiles.add(path);
    _saveFailedFiles();
  }

  void _clearFailedFile(String path) {
    _failedFiles.remove(path);
    // Persist lazily — saved at end of sync via _saveFailedFiles().
  }

  // ---- File system watcher ------------------------------------------------

  void _startFileWatcher() {
    _stopFileWatcher();
    if (_syncFolderPath == null) return;

    try {
      final dir = Directory(_syncFolderPath!);
      _watcherSubscription = dir.watch(recursive: true).listen(
        (event) {
          // Ignore hidden files and the journal file.
          final path = event.path;
          final name = path.split(Platform.pathSeparator).last;
          if (name.startsWith('.')) return;

          _log2('File watcher event: ${event.type} $path');

          // Debounce: reset the timer on every event, trigger sync after 2s of
          // quiet.
          _watcherDebounceTimer?.cancel();
          _watcherDebounceTimer = Timer(const Duration(seconds: 2), () {
            _log2('File watcher debounce triggered — running sync');
            _runSync();
          });
        },
        onError: (e) {
          _log2('File watcher error: $e');
        },
      );
      _log2('File watcher started on $_syncFolderPath');
    } catch (e) {
      _log2('Failed to start file watcher: $e');
    }
  }

  void _stopFileWatcher() {
    _watcherDebounceTimer?.cancel();
    _watcherDebounceTimer = null;
    _watcherSubscription?.cancel();
    _watcherSubscription = null;
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _stopFileWatcher();
    super.dispose();
  }
}
