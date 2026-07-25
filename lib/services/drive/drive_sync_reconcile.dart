// drive_sync_reconcile.dart — pure sync reconcile logic (NO Flutter imports).
//
// Split out of drive_sync_service.dart so it stays testable both under
// `flutter test` and a plain `dart run` harness. Decides what to copy/delete
// given the local tree, remote tree, and journal. The safety rules live here:
// a LOCAL filesystem deletion never deletes the cloud copy.

import '../../models/drive_file.dart';

enum SyncOp { mkLocalDir, mkRemoteDir, download, upload, deleteLocal, baseline }

/// Which side wins when the same file changed on both since the last sync.
enum ConflictPolicy { serverWins, localWins, newestWins }

/// Which way files flow.
enum SyncDirection { twoWay, downloadOnly, uploadOnly }

class SyncAction {
  final SyncOp op;
  final String relPath; // relative to the sync roots, '/' separators
  final DriveFile? remote; // present for download/deleteLocal/baseline
  const SyncAction(this.op, this.relPath, {this.remote});
  @override
  String toString() => '${op.name} $relPath';
}

/// A local file/dir snapshot entry.
class LocalStat {
  final bool isDir;
  final int size;
  final int mtimeMs;
  const LocalStat({required this.isDir, required this.size, required this.mtimeMs});
}

class SyncJournalEntry {
  final String fileId;
  final bool isDir;
  final int remoteUpdatedMs;
  final int size;
  final int localMtimeMs;
  const SyncJournalEntry({
    required this.fileId,
    required this.isDir,
    required this.remoteUpdatedMs,
    required this.size,
    required this.localMtimeMs,
  });

  Map<String, dynamic> toJson() => {'fileId': fileId, 'isDir': isDir, 'remoteUpdatedMs': remoteUpdatedMs, 'size': size, 'localMtimeMs': localMtimeMs};
  factory SyncJournalEntry.fromJson(Map<String, dynamic> j) => SyncJournalEntry(
        fileId: j['fileId'] as String,
        isDir: j['isDir'] == true,
        remoteUpdatedMs: (j['remoteUpdatedMs'] as num?)?.toInt() ?? 0,
        size: (j['size'] as num?)?.toInt() ?? 0,
        localMtimeMs: (j['localMtimeMs'] as num?)?.toInt() ?? 0,
      );
}

/// Pure reconcile: given the two trees and the journal, decide the actions.
/// No I/O — fully unit-testable.
///
/// [conflict] decides who wins when a file changed on BOTH sides.
/// [direction] restricts the flow: downloadOnly never writes to the server
/// (uploads/remote-mkdir suppressed), uploadOnly never writes locally
/// (downloads/local-mkdir/local-delete suppressed). Defaults reproduce the
/// original behaviour (two-way, newest-wins). Directory creations are emitted
/// shallowest-first so parents exist before children; then file operations.
List<SyncAction> reconcile({
  required Map<String, LocalStat> local,
  required Map<String, DriveFile> remote,
  required Map<String, SyncJournalEntry> journal,
  ConflictPolicy conflict = ConflictPolicy.newestWins,
  SyncDirection direction = SyncDirection.twoWay,
}) {
  final dirActions = <SyncAction>[];
  final fileActions = <SyncAction>[];
  final paths = <String>{...local.keys, ...remote.keys, ...journal.keys};

  final canDownload = direction != SyncDirection.uploadOnly; // write locally
  final canUpload = direction != SyncDirection.downloadOnly; // write to server

  // Tolerances: filesystem mtime granularity (1s) and remote clock skew (2s).
  const localTol = 1000, remoteTol = 2000;

  // Resolve a both-sides conflict into download vs upload, honouring direction.
  SyncOp resolve(int remoteMs, int localMtimeMs) {
    if (!canUpload) return SyncOp.download;
    if (!canDownload) return SyncOp.upload;
    switch (conflict) {
      case ConflictPolicy.serverWins:
        return SyncOp.download;
      case ConflictPolicy.localWins:
        return SyncOp.upload;
      case ConflictPolicy.newestWins:
        return remoteMs >= localMtimeMs ? SyncOp.download : SyncOp.upload;
    }
  }

  for (final p in paths) {
    final l = local[p];
    final r = remote[p];
    final j = journal[p];
    final isDir = (r?.isDirectory == true) || (l?.isDir == true) || (r == null && l == null && (j?.isDir ?? false));

    if (isDir) {
      if (r != null && l == null) {
        if (canDownload) dirActions.add(SyncAction(SyncOp.mkLocalDir, p, remote: r));
      } else if (l != null && r == null) {
        if (j != null) {
          // Remote dir deleted → remove local (unless uploadOnly re-creates it).
          if (direction == SyncDirection.uploadOnly) {
            if (canUpload) dirActions.add(SyncAction(SyncOp.mkRemoteDir, p));
          } else if (canDownload) {
            dirActions.add(SyncAction(SyncOp.deleteLocal, p));
          }
        } else if (canUpload) {
          dirActions.add(SyncAction(SyncOp.mkRemoteDir, p));
        }
      } else if (r != null && l != null && j == null) {
        dirActions.add(SyncAction(SyncOp.baseline, p, remote: r));
      }
      continue;
    }

    // ── files ──
    final remoteMs = r?.updatedAt?.millisecondsSinceEpoch ?? 0;

    void add(SyncOp op) {
      if (op == SyncOp.download && !canDownload) return;
      if (op == SyncOp.upload && !canUpload) return;
      if (op == SyncOp.deleteLocal && !canDownload) return;
      fileActions.add(SyncAction(op, p, remote: r));
    }

    if (j == null) {
      if (r != null && l == null) {
        add(SyncOp.download);
      } else if (l != null && r == null) {
        add(SyncOp.upload);
      } else if (r != null && l != null) {
        if (l.size == r.sizeBytes) {
          fileActions.add(SyncAction(SyncOp.baseline, p, remote: r)); // assume equal
        } else {
          add(resolve(remoteMs, l.mtimeMs)); // first-sight conflict
        }
      }
      continue;
    }

    // In journal.
    final remoteChanged = r != null && ((remoteMs - j.remoteUpdatedMs).abs() > remoteTol || r.sizeBytes != j.size);
    final localChanged = l != null && ((l.mtimeMs - j.localMtimeMs).abs() > localTol || l.size != j.size);

    if (r != null && l != null) {
      if (remoteChanged && localChanged) {
        add(resolve(remoteMs, l.mtimeMs));
      } else if (remoteChanged) {
        add(SyncOp.download);
      } else if (localChanged) {
        add(SyncOp.upload);
      } // else in sync
    } else if (r != null && l == null) {
      // Local gone. SAFE rule: never delete the remote — re-download it.
      add(SyncOp.download);
    } else if (l != null && r == null) {
      // Remote gone → cloud file deleted (via the app). Remove local, unless
      // uploadOnly (then re-create it on the server from local).
      if (direction == SyncDirection.uploadOnly) {
        add(SyncOp.upload);
      } else {
        add(SyncOp.deleteLocal);
      }
    }
  }

  dirActions.sort((a, b) => a.relPath.split('/').length.compareTo(b.relPath.split('/').length));
  return [...dirActions, ...fileActions];
}
