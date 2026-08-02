// drive_sync_service.dart — two-way folder sync against the new Drive.
//
// Bound to ONE account (its DriveApi). Mirrors a local folder with a remote
// parent (root or a chosen folder). Content is UUID-addressed remotely and
// path-addressed locally; a journal keyed by relative path bridges the two.
//
// SAFETY (mirrors the old client's proven semantics, adapted to UUIDs):
//   • new on one side → copy to the other;
//   • changed on one side → copy; changed on BOTH → newest-wins;
//   • a REMOTE deletion removes the local copy;
//   • a LOCAL filesystem deletion does NOT delete the cloud copy — it
//     re-downloads. Deleting cloud files is done through the app (trash), never
//     inferred from a missing local file. This makes a sync loop unable to
//     destroy cloud data.
//
// The reconcile step is a PURE function ([reconcile]) so its decisions are
// unit-tested deterministically; the executor just performs the I/O.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:mime/mime.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/drive_file.dart';
import 'drive_api.dart';
import 'drive_client.dart';
import 'drive_sync_reconcile.dart';

export 'drive_sync_reconcile.dart'; // re-export pure types for existing imports

// ── The service ─────────────────────────────────────────────────────────────

class DriveSyncService extends ChangeNotifier {
  final DriveApi api;
  final String accountId; // for the journal filename
  DriveSyncService(this.api, this.accountId);

  String? _folder;
  String? _remoteParentId; // null → drive root
  bool _enabled = false;
  bool _syncing = false;
  String _status = 'Not syncing';
  DateTime? _lastSync;
  int _downloaded = 0, _uploaded = 0, _deleted = 0, _errors = 0;
  String _currentFile = '';
  final List<String> _log = [];
  Map<String, SyncJournalEntry> _journal = {};
  Timer? _timer;
  StreamSubscription<FileSystemEvent>? _watch;
  Timer? _debounce;

  // ── configurable policy ─────────────────────────────────────────────────
  ConflictPolicy _conflict = ConflictPolicy.newestWins;
  SyncDirection _direction = SyncDirection.twoWay;
  bool _periodic = false; // false = immediate (watcher + 30s fallback); true = timer only
  int _intervalSeconds = 30;

  String? get syncFolder => _folder;
  bool get isEnabled => _enabled;
  bool get isSyncing => _syncing;
  String get status => _status;
  DateTime? get lastSync => _lastSync;
  int get downloaded => _downloaded;
  int get uploaded => _uploaded;
  int get deleted => _deleted;
  int get errors => _errors;
  String get currentFile => _currentFile;
  List<String> get log => List.unmodifiable(_log);

  ConflictPolicy get conflictPolicy => _conflict;
  SyncDirection get syncDirection => _direction;
  bool get isPeriodic => _periodic;
  int get intervalSeconds => _intervalSeconds;

  Future<void> setConflictPolicy(ConflictPolicy p) async {
    _conflict = p;
    await _persistConfig();
    notifyListeners();
  }

  Future<void> setSyncDirection(SyncDirection d) async {
    _direction = d;
    await _persistConfig();
    notifyListeners();
  }

  Future<void> setSchedule({bool? periodic, int? intervalSeconds}) async {
    if (periodic != null) _periodic = periodic;
    if (intervalSeconds != null) _intervalSeconds = intervalSeconds.clamp(10, 3600);
    await _persistConfig();
    if (_enabled) { stop(); start(); } // apply new cadence
    notifyListeners();
  }

  void _log2(String m) {
    debugPrint('[SYNC] $m');
    _log.add(m);
    if (_log.length > 400) _log.removeAt(0);
    notifyListeners(); // surface log lines live in the monitor
  }

  String get _journalPath => '$_folder${Platform.pathSeparator}.cloudspace_sync_$accountId.json';

  String _pk(String k) => 'sync_${accountId}_$k';

  /// Restore persisted config and resume if it was enabled.
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _folder = prefs.getString(_pk('folder'));
    _remoteParentId = prefs.getString(_pk('remoteParent'));
    _enabled = prefs.getBool(_pk('enabled')) ?? false;
    _conflict = ConflictPolicy.values.firstWhere((e) => e.name == prefs.getString(_pk('conflict')), orElse: () => ConflictPolicy.newestWins);
    _direction = SyncDirection.values.firstWhere((e) => e.name == prefs.getString(_pk('direction')), orElse: () => SyncDirection.twoWay);
    _periodic = prefs.getBool(_pk('periodic')) ?? false;
    _intervalSeconds = prefs.getInt(_pk('interval')) ?? 30;
    if (_folder != null) {
      await _reanchorMobileFolder(); // fix stale app-container paths (see below)
      await _loadJournal();
      if (_enabled) start();
    }
    notifyListeners();
  }

  // iOS reassigns the app-container UUID on reinstall/update, so a sync-folder
  // path stored under the OLD UUID (…/Containers/Data/Application/<uuid>/Documents/
  // CloudSpace) becomes invalid — the sync then fails with "Operation not
  // permitted" trying to create it. Re-anchor such an app-owned path onto the
  // CURRENT app directory. User-chosen / top-level paths are left untouched.
  Future<void> _reanchorMobileFolder() async {
    final f = _folder;
    if (f == null || !(Platform.isIOS || Platform.isAndroid)) return;
    final isAppContainer = f.contains('/Containers/Data/Application/') // iOS
        || f.contains('/Android/data/') || f.contains('/data/user/') || f.contains('/data/data/'); // Android app dirs
    if (!isAppContainer) return; // top-level / user-picked folder — don't touch
    try {
      if (await Directory(f).exists()) return; // still valid
      final i = f.indexOf('/CloudSpace');
      final tail = i >= 0 ? f.substring(i + 1) : 'CloudSpace';
      final base = Platform.isAndroid
          ? (await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory())
          : await getApplicationDocumentsDirectory();
      final rebased = '${base.path}/$tail';
      if (rebased != f) {
        _folder = rebased;
        await _persistConfig();
        _log2('re-anchored sync folder to current app directory → $rebased');
      }
    } catch (_) {/* leave the folder as-is; sync will surface the error */}
  }

  Future<void> _persistConfig() async {
    final prefs = await SharedPreferences.getInstance();
    if (_folder != null) {
      await prefs.setString(_pk('folder'), _folder!);
    } else {
      await prefs.remove(_pk('folder'));
    }
    if (_remoteParentId != null) {
      await prefs.setString(_pk('remoteParent'), _remoteParentId!);
    } else {
      await prefs.remove(_pk('remoteParent'));
    }
    await prefs.setBool(_pk('enabled'), _enabled);
    await prefs.setString(_pk('conflict'), _conflict.name);
    await prefs.setString(_pk('direction'), _direction.name);
    await prefs.setBool(_pk('periodic'), _periodic);
    await prefs.setInt(_pk('interval'), _intervalSeconds);
  }

  Future<void> setFolder(String path, {String? remoteParentId}) async {
    _folder = path;
    _remoteParentId = remoteParentId;
    final dir = Directory(path);
    if (!await dir.exists()) await dir.create(recursive: true);
    await _loadJournal();
    await _persistConfig();
    notifyListeners();
  }

  void start() {
    if (_folder == null) return;
    _enabled = true;
    _status = _periodic ? 'Scheduled every ${_intervalSeconds}s' : 'Watching for changes…';
    _persistConfig();
    notifyListeners();
    _runSync();
    _timer?.cancel();
    // Periodic mode: timer at the chosen interval. Immediate mode: file watcher
    // drives syncs, with a 30s safety-net timer.
    final period = _periodic ? _intervalSeconds : 30;
    _timer = Timer.periodic(Duration(seconds: period), (_) => _runSync());
    if (!_periodic) _startWatcher();
  }

  void stop() {
    _enabled = false;
    _timer?.cancel();
    _timer = null;
    _stopWatcher();
    _status = 'Sync stopped';
    _persistConfig();
    notifyListeners();
  }

  Future<void> syncNow() => _runSync();

  /// Forget what we think is synced: clears the journal (in memory + on disk) so
  /// the next sync re-baselines both sides purely by content/size/mtime. Use
  /// after cleaning up duplicates or when the two sides have diverged. Does NOT
  /// touch any files — only the bookkeeping.
  Future<void> resetSyncState() async {
    _journal = {};
    if (_folder != null) {
      try {
        final f = File(_journalPath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    _log2('sync state reset — next sync re-baselines from scratch');
    notifyListeners();
  }

  void _startWatcher() {
    _stopWatcher();
    if (_folder == null || Platform.isIOS || Platform.isAndroid) return;
    try {
      _watch = Directory(_folder!).watch(recursive: true).listen((e) {
        final name = e.path.split(Platform.pathSeparator).last;
        if (name.startsWith('.')) return;
        _debounce?.cancel();
        _debounce = Timer(const Duration(seconds: 2), _runSync);
      });
    } catch (e) {
      _log2('watcher failed: $e');
    }
  }

  void _stopWatcher() {
    _debounce?.cancel();
    _watch?.cancel();
    _watch = null;
  }

  Future<void> _loadJournal() async {
    try {
      final f = File(_journalPath);
      if (await f.exists()) {
        final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        _journal = m.map((k, v) => MapEntry(k, SyncJournalEntry.fromJson(v as Map<String, dynamic>)));
      } else {
        _journal = {};
      }
    } catch (e) {
      _log2('journal load failed: $e');
      _journal = {};
    }
  }

  Future<void> _saveJournal() async {
    try {
      await File(_journalPath).writeAsString(jsonEncode(_journal.map((k, v) => MapEntry(k, v.toJson()))));
    } catch (e) {
      _log2('journal save failed: $e');
    }
  }

  String _time() {
    final n = DateTime.now();
    String two(int x) => x.toString().padLeft(2, '0');
    return '${two(n.hour)}:${two(n.minute)}:${two(n.second)}';
  }

  Future<void> _runSync() async {
    if (_syncing || _folder == null) return;
    _syncing = true;
    _downloaded = _uploaded = _deleted = _errors = 0;
    _status = 'Syncing…';
    notifyListeners();
    try {
      _log2('──── sync ${_time()} · ${_direction.name} · ${_conflict.name} ────');
      await _loadJournal();
      final local = await _scanLocal();
      final remote = await _scanRemote();
      _log2('scanned: ${local.length} local, ${remote.length} remote, ${_journal.length} in journal');
      var actions = reconcile(
        local: local,
        remote: remote,
        journal: _journal,
        conflict: _conflict,
        direction: _direction,
        trace: _log2, // per-file change-detection diagnostics in the Sync Monitor
      );
      // SAFETY GUARD against data loss: a remote scan that comes back empty (or
      // far short) — a flaky/partial listing, an auth hiccup, a wrong parent — makes
      // the reconcile think every synced file was deleted on the server and wipe
      // the LOCAL copies. Never let one cycle delete all/most local files: drop the
      // local-delete actions and keep the user's files. Genuine, smaller cloud
      // deletions still propagate.
      final remoteFiles = remote.values.where((f) => !f.isDirectory).length;
      final localFiles = local.values.where((s) => !s.isDir).length;
      final localDeletes = actions.where((a) => a.op == SyncOp.deleteLocal).length;
      if (localDeletes > 0 && localFiles >= 2 && (remoteFiles == 0 || localDeletes >= localFiles)) {
        _log2('SAFETY: remote listed $remoteFiles file(s) but sync wanted to delete $localDeletes local file(s) — skipping deletions to protect your files.');
        actions = actions.where((a) => a.op != SyncOp.deleteLocal).toList();
      }
      if (actions.isEmpty) {
        _log2('nothing to do — up to date');
      } else {
        _log2('${actions.length} change(s) to apply');
        for (final a in actions) {
          if (!_enabled && _timer == null) break; // stopped mid-run
          await _apply(a);
        }
      }
      // Prune journal entries whose path vanished from both sides.
      _journal.removeWhere((p, _) => !local.containsKey(p) && !remote.containsKey(p));
      await _saveJournal();
      _lastSync = DateTime.now();
      final parts = <String>[];
      if (_downloaded > 0) parts.add('$_downloaded down');
      if (_uploaded > 0) parts.add('$_uploaded up');
      if (_deleted > 0) parts.add('$_deleted removed');
      if (_errors > 0) parts.add('$_errors errors');
      _status = parts.isEmpty ? 'Up to date' : 'Synced: ${parts.join(', ')}';
      _log2('done: ${parts.isEmpty ? 'up to date' : parts.join(', ')}');
    } catch (e) {
      _log2('SYNC ERROR: $e'); // full detail stays in the Monitor log for debugging
      _status = 'Sync error: ${friendlyError(e)}'; // clean message on the status card
    }
    _currentFile = '';
    _syncing = false;
    notifyListeners();
  }

  // Files that must never sync: hidden/dotfiles (incl. our journal), Microsoft
  // Office owner-lock files (~$doc.docx), and common OS junk. These are temporary,
  // machine-local artifacts — syncing them creates stray files and noise.
  bool _ignoredName(String name) {
    if (name.startsWith('.')) return true;
    if (name.startsWith('~\$')) return true; // MS Office lock files
    if (name.endsWith('.tmp') || name.endsWith('~')) return true;
    const junk = {'thumbs.db', 'desktop.ini', '.ds_store'};
    return junk.contains(name.toLowerCase());
  }

  Future<Map<String, LocalStat>> _scanLocal() async {
    final out = <String, LocalStat>{};
    final root = Directory(_folder!);
    // The folder can be missing if it was deleted out from under us, or on a
    // fresh mobile install where config is restored before the dir is created.
    // Recreate it so the scan (and the sync) proceeds instead of throwing.
    if (!await root.exists()) await root.create(recursive: true);
    await for (final e in root.list(recursive: true, followLinks: false)) {
      final rel = e.path.substring(root.path.length).replaceAll(Platform.pathSeparator, '/').replaceFirst(RegExp('^/'), '');
      final name = rel.split('/').last;
      if (_ignoredName(name)) continue; // hidden, journal, Office lock files, OS junk
      if (e is Directory) {
        out[rel] = const LocalStat(isDir: true, size: 0, mtimeMs: 0);
      } else if (e is File) {
        final st = await e.stat();
        out[rel] = LocalStat(isDir: false, size: st.size, mtimeMs: st.modified.millisecondsSinceEpoch);
      }
    }
    return out;
  }

  Future<Map<String, DriveFile>> _scanRemote() async {
    final out = <String, DriveFile>{};
    Future<void> walk(String? parentId, String prefix) async {
      final items = await api.listFiles(parentId: parentId, limit: 1000);
      for (final f in items) {
        if (_ignoredName(f.name)) continue; // don't sync Office lock files / OS junk
        final rel = prefix.isEmpty ? f.name : '$prefix/${f.name}';
        out[rel] = f;
        if (f.isDirectory) await walk(f.id, rel);
      }
    }

    await walk(_remoteParentId, '');
    return out;
  }

  String _localPath(String rel) => '$_folder${Platform.pathSeparator}${rel.replaceAll('/', Platform.pathSeparator)}';

  /// Resolve a rel path's remote parent id (null → sync root) by walking names.
  Future<String?> _remoteParentFor(String rel) async {
    final parts = rel.split('/');
    if (parts.length == 1) return _remoteParentId;
    String? parent = _remoteParentId;
    for (var i = 0; i < parts.length - 1; i++) {
      final items = await api.listFiles(parentId: parent, limit: 1000);
      final dir = items.where((f) => f.isDirectory && f.name == parts[i]).cast<DriveFile?>().firstWhere((_) => true, orElse: () => null);
      if (dir == null) return parent; // shouldn't happen (dirs created first)
      parent = dir.id;
    }
    return parent;
  }

  Future<void> _apply(SyncAction a) async {
    _currentFile = a.relPath.split('/').last;
    notifyListeners();
    try {
      switch (a.op) {
        case SyncOp.mkLocalDir:
          await Directory(_localPath(a.relPath)).create(recursive: true);
          _journal[a.relPath] = SyncJournalEntry(fileId: a.remote!.id, isDir: true, remoteUpdatedMs: 0, size: 0, localMtimeMs: 0);
          _log2('mkdir local ${a.relPath}');
        case SyncOp.mkRemoteDir:
          final parent = await _remoteParentFor(a.relPath);
          final created = await api.createFolder(a.relPath.split('/').last, parentId: parent);
          _journal[a.relPath] = SyncJournalEntry(fileId: created.id, isDir: true, remoteUpdatedMs: 0, size: 0, localMtimeMs: 0);
          _log2('mkdir remote ${a.relPath}');
        case SyncOp.baseline:
          final st = await File(_localPath(a.relPath)).stat();
          _journal[a.relPath] = SyncJournalEntry(fileId: a.remote!.id, isDir: a.remote!.isDirectory, remoteUpdatedMs: a.remote!.updatedAt?.millisecondsSinceEpoch ?? 0, size: a.remote!.sizeBytes, localMtimeMs: st.modified.millisecondsSinceEpoch);
        case SyncOp.download:
          final bytes = await api.download(a.remote!.id);
          final f = File(_localPath(a.relPath));
          await f.parent.create(recursive: true);
          await f.writeAsBytes(bytes);
          final st = await f.stat();
          _journal[a.relPath] = SyncJournalEntry(fileId: a.remote!.id, isDir: false, remoteUpdatedMs: a.remote!.updatedAt?.millisecondsSinceEpoch ?? 0, size: a.remote!.sizeBytes, localMtimeMs: st.modified.millisecondsSinceEpoch);
          _downloaded++;
          _log2('download ${a.relPath}');
        case SyncOp.upload:
          final path = _localPath(a.relPath);
          final name = a.relPath.split('/').last;
          final mime = lookupMimeType(name) ?? 'application/octet-stream';
          // Prefer the id we already know the file has on the server: the
          // reconcile action's remote (if present) or a prior journal entry.
          final existingId = a.remote?.id ?? _journal[a.relPath]?.fileId;
          String fileId;
          if (existingId != null) {
            // File EXISTS on the server → replace its content = a NEW VERSION of
            // the same file. This is the Drive's own editor path. Using tus here
            // would create a duplicate file (same name, new id) instead of
            // updating — the bug behind "a new corrupted file appears".
            final bytes = await File(path).readAsBytes();
            await api.replaceContent(existingId, bytes, contentType: mime);
            fileId = existingId;
            _log2('upload (new version) ${a.relPath}');
          } else {
            // Genuinely new file → tus (streams, resumable), then find it by name.
            final parent = await _remoteParentFor(a.relPath);
            await api.uploadViaTus(localPath: path, filename: name, parentId: parent, contentType: mime);
            DriveFile? committed;
            for (var i = 0; i < 10 && committed == null; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 400));
              final items = await api.listFiles(parentId: parent, limit: 1000);
              committed = items.where((f) => f.name == name && !f.isDirectory).cast<DriveFile?>().firstWhere((_) => true, orElse: () => null);
            }
            if (committed == null) {
              _errors++;
              _log2('upload ${a.relPath} — could not confirm on server');
              break;
            }
            fileId = committed.id;
            _log2('upload (new file) ${a.relPath}');
          }
          // Record the journal from FRESH server metadata so the next cycle sees
          // the file as in-sync (no spurious "remote changed" → no re-download).
          final st = await File(path).stat();
          int remoteMs;
          int remoteSize;
          try {
            final detail = await api.fileDetail(fileId);
            remoteMs = detail.updatedAt?.millisecondsSinceEpoch ?? DateTime.now().millisecondsSinceEpoch;
            remoteSize = detail.sizeBytes;
          } catch (_) {
            remoteMs = DateTime.now().millisecondsSinceEpoch;
            remoteSize = st.size;
          }
          _journal[a.relPath] = SyncJournalEntry(fileId: fileId, isDir: false, remoteUpdatedMs: remoteMs, size: remoteSize, localMtimeMs: st.modified.millisecondsSinceEpoch);
          _uploaded++;
        case SyncOp.deleteLocal:
          final f = File(_localPath(a.relPath));
          final d = Directory(_localPath(a.relPath));
          if (await f.exists()) await f.delete();
          if (await d.exists()) await d.delete(recursive: true);
          _journal.remove(a.relPath);
          _deleted++;
          _log2('delete local ${a.relPath}');
      }
      await _saveJournal();
    } catch (e) {
      _errors++;
      _log2('FAIL ${a.op.name} ${a.relPath}: $e');
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _stopWatcher();
    super.dispose();
  }
}
