// ignore_for_file: avoid_print
// Live sync verification: exercises the real reconcile() decisions against the
// real DriveApi (tus upload, download, trash) with a temp local folder and a
// dedicated remote folder, covering push, pull, and remote-delete→local-delete.
//
//   dart run tool/verify_sync.dart <baseUrl> <dk_token>

import 'dart:io';
import 'package:cloudspace_app/models/drive_file.dart';
import 'package:cloudspace_app/services/drive/drive_client.dart';
import 'package:cloudspace_app/services/drive/drive_api.dart';
import 'package:cloudspace_app/services/drive/drive_sync_reconcile.dart';
import 'package:mime/mime.dart';

int _pass = 0, _fail = 0;
void ok(String m) { _pass++; print('  ✓ $m'); }
void bad(String m, Object e) { _fail++; print('  ✗ $m — $e'); }

Future<Map<String, LocalStat>> scanLocal(Directory root) async {
  final out = <String, LocalStat>{};
  await for (final e in root.list(recursive: true, followLinks: false)) {
    final rel = e.path.substring(root.path.length).replaceAll(Platform.pathSeparator, '/').replaceFirst(RegExp('^/'), '');
    if (rel.split('/').last.startsWith('.')) continue;
    if (e is Directory) {
      out[rel] = const LocalStat(isDir: true, size: 0, mtimeMs: 0);
    } else if (e is File) {
      final st = await e.stat();
      out[rel] = LocalStat(isDir: false, size: st.size, mtimeMs: st.modified.millisecondsSinceEpoch);
    }
  }
  return out;
}

Future<Map<String, DriveFile>> scanRemote(DriveApi api, String? parentId) async {
  final out = <String, DriveFile>{};
  Future<void> walk(String? p, String prefix) async {
    for (final f in await api.listFiles(parentId: p, limit: 1000)) {
      final rel = prefix.isEmpty ? f.name : '$prefix/${f.name}';
      out[rel] = f;
      if (f.isDirectory) await walk(f.id, rel);
    }
  }
  await walk(parentId, '');
  return out;
}

Future<void> main(List<String> args) async {
  final api = DriveApi(DriveClient(baseUrl: args[0], token: args[1]));
  final stamp = DateTime.now().microsecondsSinceEpoch;
  final local = Directory('${Directory.systemTemp.path}/cs_sync_$stamp')..createSync();
  DriveFile? remoteRoot;

  try {
    remoteRoot = await api.createFolder('cs_synctest_$stamp');
    ok('remote sync root created');

    // 1. PUSH: a new local file should upload.
    await File('${local.path}/note.txt').writeAsString('hello sync');
    var actions = reconcile(local: await scanLocal(local), remote: await scanRemote(api, remoteRoot.id), journal: {});
    if (actions.any((a) => a.op == SyncOp.upload && a.relPath == 'note.txt')) {
      ok('reconcile → upload note.txt');
      final f = File('${local.path}/note.txt');
      await api.uploadViaTus(localPath: f.path, filename: 'note.txt', parentId: remoteRoot.id, contentType: lookupMimeType('note.txt') ?? 'text/plain');
      DriveFile? up;
      for (var i = 0; i < 10 && up == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        final items = await api.listFiles(parentId: remoteRoot.id);
        up = items.where((x) => x.name == 'note.txt').cast<DriveFile?>().firstWhere((_) => true, orElse: () => null);
      }
      up != null ? ok('pushed file now on Drive') : bad('push', 'file did not appear on Drive');
    } else {
      bad('reconcile push', 'no upload action');
    }

    // 2. PULL: a new remote file should download.
    await api.createFile('txt', name: 'remote_note', parentId: remoteRoot.id);
    final remoteMap = await scanRemote(api, remoteRoot.id);
    // journal for note.txt so it isn't re-uploaded; leave remote_note.txt unknown.
    actions = reconcile(local: await scanLocal(local), remote: remoteMap, journal: {});
    final dl = actions.where((a) => a.op == SyncOp.download).toList();
    if (dl.any((a) => a.relPath.startsWith('remote_note'))) {
      ok('reconcile → download remote_note');
      final rf = remoteMap.entries.firstWhere((e) => e.key.startsWith('remote_note')).value;
      final bytes = await api.download(rf.id);
      await File('${local.path}/${rf.name}').writeAsBytes(bytes);
      File('${local.path}/${rf.name}').existsSync() ? ok('pulled file now local') : bad('pull', 'local file missing');
    } else {
      bad('reconcile pull', 'no download action');
    }

    // 3. REMOTE DELETE → LOCAL DELETE. Trash note.txt on the server; with a
    //    journal entry present, reconcile should delete the local copy.
    final rmap = await scanRemote(api, remoteRoot.id);
    final noteRemote = rmap['note.txt']!;
    await api.trash(noteRemote.id);
    final journal = {
      'note.txt': SyncJournalEntry(fileId: noteRemote.id, isDir: false, remoteUpdatedMs: noteRemote.updatedAt?.millisecondsSinceEpoch ?? 0, size: noteRemote.sizeBytes, localMtimeMs: (await File('${local.path}/note.txt').stat()).modified.millisecondsSinceEpoch),
    };
    actions = reconcile(local: await scanLocal(local), remote: await scanRemote(api, remoteRoot.id), journal: journal);
    if (actions.any((a) => a.op == SyncOp.deleteLocal && a.relPath == 'note.txt')) {
      ok('reconcile → deleteLocal note.txt (remote deleted)');
      await File('${local.path}/note.txt').delete();
      !File('${local.path}/note.txt').existsSync() ? ok('local copy removed') : bad('delete', 'local file still there');
    } else {
      bad('reconcile delete', 'no deleteLocal action');
    }

    // 4. SAFETY: local-only deletion must NOT delete remote (re-download).
    final safeActions = reconcile(
      local: {},
      remote: {'x.txt': DriveFile(id: 'rid', isDirectory: false, name: 'x.txt', sizeBytes: 5, updatedAt: DateTime.fromMillisecondsSinceEpoch(1000))},
      journal: {'x.txt': const SyncJournalEntry(fileId: 'rid', isDir: false, remoteUpdatedMs: 1000, size: 5, localMtimeMs: 1000)},
    );
    (safeActions.every((a) => a.op != SyncOp.deleteLocal) && safeActions.any((a) => a.op == SyncOp.download))
        ? ok('SAFETY: local delete → re-download, never touches remote')
        : bad('safety', 'unexpected actions: $safeActions');
  } catch (e) {
    bad('sync flow', e);
  } finally {
    try { local.deleteSync(recursive: true); } catch (_) {}
    if (remoteRoot != null) {
      try {
        await api.trash(remoteRoot.id);
        final tr = await api.listTrash();
        final tf = tr.where((t) => t.id == remoteRoot!.id).cast<DriveFile?>().firstWhere((_) => true, orElse: () => null);
        if (tf != null) await api.purgeTrash(tf.id);
      } catch (_) {}
    }
  }

  print('\n== $_pass passed, $_fail failed ==');
  exit(_fail == 0 ? 0 : 1);
}
