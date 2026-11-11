// The tester's case (TC-008): this device edits a file, someone else saves the
// same file on the Drive just before the upload. The server refuses the upload
// (412, changed since the last sync) and the conflict setting decides —
// instead of the other save silently replacing this device's edit or vice versa.
import 'dart:convert';
import 'dart:io';

import 'package:cloudspace_app/services/drive/drive_api.dart';
import 'package:cloudspace_app/services/drive/drive_client.dart';
import 'package:cloudspace_app/services/drive/drive_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const t0 = '2026-11-11T15:00:00.123456Z'; // what this device last synced
const t1 = '2026-11-11T15:00:05.654321Z'; // the other person's save

Map<String, dynamic> _file(String updated, int size) =>
    {'id': 'f1', 'kind': 'file', 'name': 'a.txt', 'size_bytes': size, 'updated_at': updated};

Future<({List<http.Request> puts, Directory dir, int downloads})> _run(ConflictPolicy policy) async {
  SharedPreferences.setMockInitialValues({});
  final dir = await Directory.systemTemp.createTemp('late_conflict');
  // Synced at t0 (3 bytes); then edited on this device.
  final local = File('${dir.path}/a.txt');
  await local.writeAsString('mine!!');
  await File('${dir.path}/.cloudspace_sync_acct.json').writeAsString(jsonEncode({
    'a.txt': {
      'fileId': 'f1',
      'isDir': false,
      'remoteUpdatedMs': DateTime.parse(t0).millisecondsSinceEpoch,
      'size': 3,
      'localMtimeMs': DateTime.now().subtract(const Duration(hours: 1)).millisecondsSinceEpoch,
    }
  }));

  final puts = <http.Request>[];
  var downloads = 0;
  var serverUpdated = t0;
  final api = DriveApi(DriveClient(
    baseUrl: 'https://drive.test',
    token: 'dk_test',
    httpClient: MockClient((req) async {
      Map<String, String> json = {'content-type': 'application/json'};
      final key = '${req.method} ${req.url.path}';
      if (key == 'GET /api/v1/files') {
        // The scan still sees t0: the other save lands right after it.
        final r = http.Response(jsonEncode({'data': {'items': [_file(t0, 3)]}}), 200, headers: json);
        serverUpdated = t1;
        return r;
      }
      if (key == 'PUT /api/v1/files/f1/content') {
        puts.add(req);
        final base = req.headers['X-Drive-Base-Updated-At'] ?? req.headers['x-drive-base-updated-at'];
        if (base != null && DateTime.parse(base).millisecondsSinceEpoch != DateTime.parse(serverUpdated).millisecondsSinceEpoch) {
          return http.Response(jsonEncode({'error': {'code': 'changed_since', 'message': 'changed'}}), 412, headers: json);
        }
        serverUpdated = '2026-11-11T15:00:09.000000Z';
        return http.Response(jsonEncode({'data': {'id': 'f1'}}), 200, headers: json);
      }
      if (key == 'GET /api/v1/files/f1') {
        return http.Response(jsonEncode({'data': _file(serverUpdated, 6)}), 200, headers: json);
      }
      if (key == 'GET /api/v1/files/f1/content') {
        downloads++;
        return http.Response('theirs', 200);
      }
      return http.Response('{"error":{"code":"not_found","message":"x"}}', 404, headers: json);
    }),
  ));
  final sync = DriveSyncService(api, 'acct');
  await sync.setConflictPolicy(policy);
  await sync.setSchedule(periodic: true, intervalSeconds: 3600); // no file watcher
  await sync.setFolder(dir.path);
  sync.start();
  for (var i = 0; i < 200 && (sync.isSyncing || sync.lastSync == null); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  sync.stop();
  return (puts: puts, dir: dir, downloads: downloads);
}

void main() {
  test('Keep this device\'s version: refused upload is retried over the newer save', () async {
    final r = await _run(ConflictPolicy.localWins);
    expect(r.puts, hasLength(2));
    expect(DateTime.parse(r.puts[0].headers['X-Drive-Base-Updated-At']!).millisecondsSinceEpoch,
        DateTime.parse(t0).millisecondsSinceEpoch); // first try: only over what it knew
    expect(DateTime.parse(r.puts[1].headers['X-Drive-Base-Updated-At']!).millisecondsSinceEpoch,
        DateTime.parse(t1).millisecondsSinceEpoch); // then, knowingly, over the other save
    expect(r.puts[1].body, 'mine!!');
    expect(r.downloads, 0);
    expect(await File('${r.dir.path}/a.txt').readAsString(), 'mine!!');
  });

  test('Keep the Drive\'s version: the other save comes down, this edit is kept as a conflict copy', () async {
    final r = await _run(ConflictPolicy.serverWins);
    expect(r.puts, hasLength(1)); // only the refused try
    expect(r.downloads, 1);
    expect(await File('${r.dir.path}/a.txt').readAsString(), 'theirs');
    final copies = r.dir.listSync().whereType<File>().where((f) => f.path.contains('(conflict copy ')).toList();
    expect(copies, hasLength(1));
    expect(await copies.single.readAsString(), 'mine!!');
  });
}
