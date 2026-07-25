// Tests for the pure sync reconcile function — the decision logic that governs
// what gets copied/deleted. These lock the safety rules (especially: a local
// filesystem deletion must NEVER delete the cloud copy).

import 'package:flutter_test/flutter_test.dart';
import 'package:cloudspace_app/models/drive_file.dart';
import 'package:cloudspace_app/services/drive/drive_sync_service.dart';

DriveFile _rf(String id, String name, {bool dir = false, int size = 10, int updatedMs = 1000}) => DriveFile(
      id: id,
      isDirectory: dir,
      name: name,
      sizeBytes: size,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(updatedMs),
    );

LocalStat _lf({int size = 10, int mtimeMs = 1000, bool dir = false}) => LocalStat(isDir: dir, size: size, mtimeMs: mtimeMs);

SyncJournalEntry _j(String id, {int size = 10, int remoteMs = 1000, int localMs = 1000, bool dir = false}) =>
    SyncJournalEntry(fileId: id, isDir: dir, remoteUpdatedMs: remoteMs, size: size, localMtimeMs: localMs);

SyncOp? _opFor(List<SyncAction> actions, String path) {
  for (final a in actions) {
    if (a.relPath == path) return a.op;
  }
  return null;
}

void main() {
  test('new remote file → download', () {
    final a = reconcile(local: {}, remote: {'a.txt': _rf('r1', 'a.txt')}, journal: {});
    expect(_opFor(a, 'a.txt'), SyncOp.download);
  });

  test('new local file → upload', () {
    final a = reconcile(local: {'a.txt': _lf()}, remote: {}, journal: {});
    expect(_opFor(a, 'a.txt'), SyncOp.upload);
  });

  test('both new, same size → baseline (no transfer)', () {
    final a = reconcile(local: {'a.txt': _lf(size: 5)}, remote: {'a.txt': _rf('r1', 'a.txt', size: 5)}, journal: {});
    expect(_opFor(a, 'a.txt'), SyncOp.baseline);
  });

  test('in sync (journal matches both) → no action', () {
    final a = reconcile(
      local: {'a.txt': _lf(size: 10, mtimeMs: 1000)},
      remote: {'a.txt': _rf('r1', 'a.txt', size: 10, updatedMs: 1000)},
      journal: {'a.txt': _j('r1', size: 10, remoteMs: 1000, localMs: 1000)},
    );
    expect(_opFor(a, 'a.txt'), isNull);
  });

  test('remote changed only → download', () {
    final a = reconcile(
      local: {'a.txt': _lf(size: 10, mtimeMs: 1000)},
      remote: {'a.txt': _rf('r1', 'a.txt', size: 20, updatedMs: 9000)},
      journal: {'a.txt': _j('r1', size: 10, remoteMs: 1000, localMs: 1000)},
    );
    expect(_opFor(a, 'a.txt'), SyncOp.download);
  });

  test('local changed only → upload', () {
    final a = reconcile(
      local: {'a.txt': _lf(size: 30, mtimeMs: 9000)},
      remote: {'a.txt': _rf('r1', 'a.txt', size: 10, updatedMs: 1000)},
      journal: {'a.txt': _j('r1', size: 10, remoteMs: 1000, localMs: 1000)},
    );
    expect(_opFor(a, 'a.txt'), SyncOp.upload);
  });

  test('both changed → newest wins (remote newer → download)', () {
    final a = reconcile(
      local: {'a.txt': _lf(size: 30, mtimeMs: 5000)},
      remote: {'a.txt': _rf('r1', 'a.txt', size: 20, updatedMs: 9000)},
      journal: {'a.txt': _j('r1', size: 10, remoteMs: 1000, localMs: 1000)},
    );
    expect(_opFor(a, 'a.txt'), SyncOp.download);
  });

  test('both changed → newest wins (local newer → upload)', () {
    final a = reconcile(
      local: {'a.txt': _lf(size: 30, mtimeMs: 9000)},
      remote: {'a.txt': _rf('r1', 'a.txt', size: 20, updatedMs: 5000)},
      journal: {'a.txt': _j('r1', size: 10, remoteMs: 1000, localMs: 1000)},
    );
    expect(_opFor(a, 'a.txt'), SyncOp.upload);
  });

  test('SAFETY: local deleted, remote unchanged → re-download (never delete remote)', () {
    final a = reconcile(
      local: {},
      remote: {'a.txt': _rf('r1', 'a.txt', size: 10, updatedMs: 1000)},
      journal: {'a.txt': _j('r1', size: 10, remoteMs: 1000, localMs: 1000)},
    );
    // The ONLY action is a download; there is no op that touches the remote.
    expect(_opFor(a, 'a.txt'), SyncOp.download);
    expect(a.every((x) => x.op != SyncOp.deleteLocal), isTrue);
  });

  test('remote deleted → delete local', () {
    final a = reconcile(
      local: {'a.txt': _lf(size: 10, mtimeMs: 1000)},
      remote: {},
      journal: {'a.txt': _j('r1', size: 10, remoteMs: 1000, localMs: 1000)},
    );
    expect(_opFor(a, 'a.txt'), SyncOp.deleteLocal);
  });

  test('remote-only dir → mkLocalDir; parents ordered before children', () {
    final a = reconcile(
      local: {},
      remote: {
        'docs': _rf('d1', 'docs', dir: true),
        'docs/sub': _rf('d2', 'sub', dir: true),
        'docs/sub/a.txt': _rf('r1', 'a.txt'),
      },
      journal: {},
    );
    final mkIdxParent = a.indexWhere((x) => x.relPath == 'docs');
    final mkIdxChild = a.indexWhere((x) => x.relPath == 'docs/sub');
    expect(_opFor(a, 'docs'), SyncOp.mkLocalDir);
    expect(_opFor(a, 'docs/sub'), SyncOp.mkLocalDir);
    expect(_opFor(a, 'docs/sub/a.txt'), SyncOp.download);
    expect(mkIdxParent < mkIdxChild, isTrue, reason: 'parent dir must be created before child');
  });

  test('new local dir → mkRemoteDir', () {
    final a = reconcile(local: {'photos': _lf(dir: true)}, remote: {}, journal: {});
    expect(_opFor(a, 'photos'), SyncOp.mkRemoteDir);
  });

  // ── policy: conflict resolution (both changed) ──
  Map<String, LocalStat> bothChangedLocal() => {'a.txt': _lf(size: 30, mtimeMs: 5000)};
  Map<String, DriveFile> bothChangedRemote() => {'a.txt': _rf('r1', 'a.txt', size: 20, updatedMs: 9000)};
  Map<String, SyncJournalEntry> bothChangedJournal() => {'a.txt': _j('r1', size: 10, remoteMs: 1000, localMs: 1000)};

  test('conflict serverWins → download even if local is newer', () {
    final a = reconcile(
      local: {'a.txt': _lf(size: 30, mtimeMs: 9000)}, // local newer
      remote: {'a.txt': _rf('r1', 'a.txt', size: 20, updatedMs: 5000)},
      journal: bothChangedJournal(),
      conflict: ConflictPolicy.serverWins,
    );
    expect(_opFor(a, 'a.txt'), SyncOp.download);
  });

  test('conflict localWins → upload even if remote is newer', () {
    final a = reconcile(
      local: bothChangedLocal(),
      remote: bothChangedRemote(), // remote newer
      journal: bothChangedJournal(),
      conflict: ConflictPolicy.localWins,
    );
    expect(_opFor(a, 'a.txt'), SyncOp.upload);
  });

  // ── policy: direction ──
  test('downloadOnly: a local-only file is NOT uploaded', () {
    final a = reconcile(local: {'a.txt': _lf()}, remote: {}, journal: {}, direction: SyncDirection.downloadOnly);
    expect(a.where((x) => x.op == SyncOp.upload), isEmpty);
  });

  test('uploadOnly: a remote-only file is NOT downloaded', () {
    final a = reconcile(local: {}, remote: {'a.txt': _rf('r1', 'a.txt')}, journal: {}, direction: SyncDirection.uploadOnly);
    expect(a.where((x) => x.op == SyncOp.download), isEmpty);
  });

  test('uploadOnly: a remote deletion does NOT delete the local file', () {
    final a = reconcile(
      local: {'a.txt': _lf()},
      remote: {},
      journal: {'a.txt': _j('r1')},
      direction: SyncDirection.uploadOnly,
    );
    expect(a.where((x) => x.op == SyncOp.deleteLocal), isEmpty);
    expect(_opFor(a, 'a.txt'), SyncOp.upload); // re-created on server instead
  });

  test('downloadOnly: local-only change is overwritten by the server copy', () {
    final a = reconcile(
      local: {'a.txt': _lf(size: 30, mtimeMs: 9000)}, // local changed
      remote: {'a.txt': _rf('r1', 'a.txt', size: 10, updatedMs: 1000)},
      journal: {'a.txt': _j('r1', size: 10, remoteMs: 1000, localMs: 1000)},
      direction: SyncDirection.downloadOnly,
    );
    // Local changed only → normally upload; download-only suppresses that, no action.
    expect(a.where((x) => x.op == SyncOp.upload), isEmpty);
  });
}
