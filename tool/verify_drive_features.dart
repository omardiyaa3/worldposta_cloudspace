// ignore_for_file: avoid_print
// Live check of the app's web-parity features against a real backend:
// pin, shortcuts, tags, notifications, export, print preview, Google Drive.
//
//   dart run tool/verify_drive_features.dart <baseUrl> <dk_token>
//
// Works in a temporary folder and removes everything it creates. Sends no
// email (that would reach a real inbox).

import 'dart:io';
import 'package:cloudspace_app/services/drive/drive_client.dart';
import 'package:cloudspace_app/services/drive/drive_api.dart';

int _pass = 0, _fail = 0;
Future<void> check(String name, Future<String> Function() body) async {
  try {
    print('  ✓ $name — ${await body()}');
    _pass++;
  } catch (e) {
    print('  ✗ $name — $e');
    _fail++;
  }
}

void expect(bool cond, String what) {
  if (!cond) throw StateError(what);
}

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: dart run tool/verify_drive_features.dart <baseUrl> <dk_token>');
    exit(2);
  }
  final c = DriveClient(baseUrl: args[0], token: args[1]);
  final api = DriveApi(c);
  final stamp = DateTime.now().millisecondsSinceEpoch;
  final folder = await api.createFolder('App feature check $stamp');
  final doc = await api.createFile('docx', name: 'Check $stamp.docx', parentId: folder.id);
  String? tagId;
  try {
    await check('pin / unpin', () async {
      await api.pin(doc.id);
      expect((await api.listPinned()).any((f) => f.id == doc.id), 'not in Pinned');
      await api.unpin(doc.id);
      expect(!(await api.listPinned()).any((f) => f.id == doc.id), 'still pinned');
      return 'listed, then gone';
    });
    await check('shortcut add / remove', () async {
      await api.addShortcut(doc.id);
      final s = (await api.listShortcuts()).where((f) => f.id == doc.id).toList();
      expect(s.isNotEmpty && s.first.shortcutId != null, 'no shortcut row');
      await api.removeShortcut(s.first.shortcutId!);
      expect(!(await api.listShortcuts()).any((f) => f.id == doc.id), 'shortcut left');
      expect((await api.fileDetail(doc.id)).id == doc.id, 'original gone');
      return 'listed with shortcut_id, removed, original kept';
    });
    await check('tags create / attach / filter / detach', () async {
      final t = await api.createTag('appcheck-$stamp');
      tagId = t.id;
      await api.attachTag(doc.id, t.id);
      expect((await api.fileTags(doc.id)).any((x) => x.id == t.id), 'tag not on file');
      expect((await api.listByTag(t.id)).any((f) => f.id == doc.id), 'file not under tag');
      await api.detachTag(doc.id, t.id);
      expect(!(await api.fileTags(doc.id)).any((x) => x.id == t.id), 'tag still on file');
      return 'tag "${t.name}" round-trip';
    });
    await check('notifications', () async {
      final n = await api.notifications();
      return '${n.items.length} item(s), ${n.unread} unread';
    });
    await check('export docx → pdf', () async {
      final b = await api.convert(doc.id, 'pdf');
      expect(b.length > 4 && String.fromCharCodes(b.take(4)) == '%PDF', 'not a PDF (${b.length} bytes)');
      return '${b.length} bytes of PDF';
    });
    await check('print preview (pdf)', () async {
      // Same as the app: background preview, or convert on demand.
      final b = await api.previewPdf(doc.id).catchError((Object e) =>
          e is DriveException && e.isNotFound ? api.convert(doc.id, 'pdf') : throw e);
      expect(b.length > 4 && String.fromCharCodes(b.take(4)) == '%PDF', 'not a PDF (${b.length} bytes)');
      return '${b.length} bytes of PDF';
    });
    await check('google connection + browse', () async {
      final g = await api.googleConnection();
      if (!g.connected) return 'configured=${g.configured}, not connected (browse skipped)';
      final p = await api.googleBrowse();
      return 'connected as ${g.email}; top level ${p.items.length} item(s)';
    });
  } finally {
    if (tagId != null) {
      try { await c.delete('/api/v1/tags/$tagId'); } catch (e) { print('  ! tag cleanup: $e'); }
    }
    try {
      await api.trash(folder.id);
      await api.purgeTrash(folder.id);
    } catch (e) {
      print('  ! folder cleanup: $e');
    }
  }
  print('\n$_pass passed, $_fail failed');
  exit(_fail == 0 ? 0 : 1);
}
