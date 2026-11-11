// The web features brought to the app: Google Drive, shortcuts/pinned, tags,
// notifications, send/export. API calls are checked against a mock HTTP client
// (paths + bodies match the Go handlers); the screens run on the same fake.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:cloudspace_app/models/drive_file.dart';
import 'package:cloudspace_app/screens/drive/drive_google_screen.dart';
import 'package:cloudspace_app/services/drive/drive_google_connect.dart';
import 'package:cloudspace_app/services/drive/drive_api.dart';
import 'package:cloudspace_app/services/drive/drive_client.dart';
import 'package:cloudspace_app/widgets/notification_bell.dart';

/// A fake Drive server: answers by "METHOD /path" and records every request.
class _Fake {
  final List<http.Request> calls = [];
  final Map<String, http.Response Function(http.Request)> routes = {};

  void on(String key, Object data, {int status = 200}) =>
      routes[key] = (_) => http.Response(jsonEncode(status < 300 ? {'data': data} : data), status,
          headers: {'content-type': 'application/json'});

  DriveApi api() => DriveApi(DriveClient(
        baseUrl: 'https://drive.test',
        token: 'dk_test',
        httpClient: MockClient((req) async {
          calls.add(req);
          final h = routes['${req.method} ${req.url.path}'];
          return h != null ? h(req) : http.Response('{"error":{"code":"not_found","message":"x"}}', 404);
        }),
      ));

  http.Request last(String method, String path) =>
      calls.lastWhere((r) => r.method == method && r.url.path == path);
}

Map<String, dynamic> _body(http.Request r) => jsonDecode(r.body) as Map<String, dynamic>;

void main() {
  group('API', () {
    test('Google: browse top level vs a folder, web link fallback, copy into Posta Drive', () async {
      final f = _Fake()
        ..on('GET /api/v1/imports/google/browse', {
          'items': [
            {'id': 'g1', 'name': 'Plans', 'mime_type': 'application/vnd.google-apps.folder', 'is_folder': true},
            {'id': 'g2', 'name': 'a.pdf', 'mime_type': 'application/pdf', 'size': 10, 'web_view_link': 'https://docs.google.com/x'},
          ],
          'next_page_token': 'p2',
        })
        ..on('POST /api/v1/imports/google/start', {'job_id': 'j1'});
      final api = f.api();

      final top = await api.googleBrowse();
      expect(f.calls.last.url.queryParameters.containsKey('folder'), isFalse);
      expect(top.items.map((i) => i.id), ['g1', 'g2']);
      expect(top.items.first.isFolder, isTrue);
      expect(top.items.first.webViewLink, 'https://drive.google.com/open?id=g1'); // fallback
      expect(top.items.last.webViewLink, 'https://docs.google.com/x');
      expect(top.nextPageToken, 'p2');

      await api.googleBrowse(folder: 'g1', pageToken: 'p2');
      expect(f.calls.last.url.queryParameters, {'folder': 'g1', 'page_token': 'p2'});

      expect(await api.googleImport(['g1', 'g2'], targetFolderId: 'f9'), 'j1');
      expect(_body(f.last('POST', '/api/v1/imports/google/start')),
          {'mode': 'selected', 'items': ['g1', 'g2'], 'target_folder_id': 'f9', 'import_sharing': true});
      await api.googleImport(['g2']);
      expect(_body(f.calls.last)['target_folder_id'], isNull); // My Drive
    });

    test('shortcuts and pins hit the shortcut / pin routes', () async {
      final f = _Fake()
        ..on('GET /api/v1/discovery/shortcuts', {
          'items': [
            {'id': 'target', 'kind': 'file', 'name': 'x.docx', 'size_bytes': 1, 'shortcut_id': 's1'}
          ]
        })
        ..on('POST /api/v1/files/f1/shortcut', {'id': 's2'})
        ..on('DELETE /api/v1/shortcuts/s1', {'ok': true})
        ..on('POST /api/v1/files/f1/pin', {'ok': true})
        ..on('DELETE /api/v1/files/f1/pin', {'ok': true})
        ..on('GET /api/v1/pinned', {'items': []});
      final api = f.api();
      final list = await api.listShortcuts();
      expect(list.single.shortcutId, 's1');
      expect(list.single.id, 'target');
      await api.addShortcut('f1');
      await api.removeShortcut('s1');
      await api.pin('f1');
      await api.unpin('f1');
      expect(await api.listPinned(), isEmpty);
      expect(f.calls.map((r) => '${r.method} ${r.url.path}'), [
        'GET /api/v1/discovery/shortcuts',
        'POST /api/v1/files/f1/shortcut',
        'DELETE /api/v1/shortcuts/s1',
        'POST /api/v1/files/f1/pin',
        'DELETE /api/v1/files/f1/pin',
        'GET /api/v1/pinned',
      ]);
    });

    test('tags: list, create, attach by tag_id, detach, files by tag', () async {
      final f = _Fake()
        ..on('GET /api/v1/tags', {
          'items': [{'id': 't1', 'name': 'Finance', 'color': '#4f46e5'}]
        })
        ..on('POST /api/v1/tags', {'id': 't2', 'name': 'Q4', 'color': '#10b981'}, status: 201)
        ..on('POST /api/v1/files/f1/tags', {'ok': true})
        ..on('DELETE /api/v1/files/f1/tags/t1', {'ok': true})
        ..on('GET /api/v1/files', {'items': []});
      // 201 with a data envelope still unwraps.
      f.routes['POST /api/v1/tags'] = (_) => http.Response(
          jsonEncode({'data': {'id': 't2', 'name': 'Q4', 'color': '#10b981'}}), 201);
      final api = f.api();
      expect((await api.listTags()).single.name, 'Finance');
      expect((await api.createTag('Q4')).id, 't2');
      expect(_body(f.calls.last), {'name': 'Q4'});
      await api.attachTag('f1', 't2');
      expect(_body(f.calls.last), {'tag_id': 't2'});
      await api.detachTag('f1', 't1');
      await api.listByTag('t1');
      expect(f.calls.last.url.queryParameters['tag'], 't1');
    });

    test('notifications: unread count, read flag, mark all', () async {
      final f = _Fake()
        ..on('GET /api/v1/notifications', {
          'items': [
            {'id': 'n1', 'kind': 'share', 'title': 'Ann shared a file', 'body': '', 'created_at': '2026-10-18T10:00:00Z'},
            {'id': 'n2', 'kind': 'comment', 'title': 'Old', 'body': '', 'read_at': '2026-10-17T10:00:00Z'},
          ],
          'unread': 1,
        })
        ..on('POST /api/v1/notifications/read-all', {'ok': true})
        ..on('POST /api/v1/notifications/n1/read', {'ok': true});
      final api = f.api();
      final r = await api.notifications();
      expect(r.unread, 1);
      expect(r.items.map((n) => n.read), [false, true]);
      await api.markNotificationRead('n1');
      await api.markAllNotificationsRead();
      expect(f.calls.last.url.path, '/api/v1/notifications/read-all');
    });

    test('send by email + export (POST convert?to=, bytes back)', () async {
      final f = _Fake()..on('POST /api/v1/files/f1/email', {'queued': true});
      f.routes['POST /api/v1/files/f1/convert'] = (_) => http.Response.bytes([37, 80, 68, 70], 200);
      final api = f.api();
      await api.emailFile('f1', to: 'a@b.com', subject: 'Hi', body: 'see', attach: false);
      expect(_body(f.calls.last), {'to': 'a@b.com', 'subject': 'Hi', 'body': 'see', 'attach': false});
      final bytes = await api.convert('f1', 'pdf');
      expect(bytes, [37, 80, 68, 70]);
      expect(f.calls.last.method, 'POST');
      expect(f.calls.last.url.queryParameters, {'to': 'pdf'});
    });

    test('export targets follow the web table', () {
      DriveFile file(String name) => DriveFile(id: 'x', isDirectory: false, name: name);
      expect(driveExportTargetsFor(file('a.docx')), ['pdf', 'odt', 'html', 'txt']);
      expect(driveExportTargetsFor(file('b.CSV')), ['pdf', 'xlsx', 'html']);
      expect(driveExportTargetsFor(file('c.png')), isEmpty);
      expect(driveExportTargetsFor(const DriveFile(id: 'd', isDirectory: true, name: 'docs.docx')), isEmpty);
    });
  });

  group('Google Drive screen', () {
    final connects = <String>[];
    var connectResult = const GoogleConnectResult(GoogleConnectStatus.cancelled);
    Future<List<Uri>> pump(WidgetTester t, _Fake f) async {
      final launched = <Uri>[];
      connects.clear();
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: DriveGoogleScreen(
            api: f.api(),
            serverUrl: 'https://drive.test',
            launcher: (u) async {
              launched.add(u);
              return true;
            },
            connector: (api, server) async {
              connects.add(server);
              return connectResult;
            },
          ),
        ),
      ));
      await t.pumpAndSettle();
      return launched;
    }

    testWidgets('not connected: Connect runs the in-app flow, then shows what was picked', (t) async {
      var connected = false;
      final f = _Fake();
      f.routes['GET /api/v1/imports/google/connection'] = (_) =>
          http.Response(jsonEncode({'data': {'configured': true, 'connected': connected}}), 200);
      f.on('GET /api/v1/imports/google/browse', {
        'items': [
          {'id': 'g9', 'name': 'Picked.pdf', 'mime_type': 'application/pdf'}
        ],
        'next_page_token': '',
      });
      final launched = await pump(t, f);
      expect(find.text('Connect Google Drive'), findsOneWidget);
      expect(f.calls.where((r) => r.url.path.endsWith('/browse')), isEmpty);

      connected = true;
      connectResult = const GoogleConnectResult(GoogleConnectStatus.picked, 1);
      await t.tap(find.text('Connect Google Drive'));
      await t.pumpAndSettle();
      expect(connects, ['https://drive.test']);
      expect(launched, isEmpty); // no outside browser link
      expect(find.text('Added 1 item from Google Drive.'), findsOneWidget);
      expect(find.text('Picked.pdf'), findsOneWidget);
    });

    testWidgets('connected: lists items, opens a folder, files open in Google', (t) async {
      final f = _Fake()
        ..on('GET /api/v1/imports/google/connection', {'configured': true, 'connected': true, 'email': 'me@gmail.com'});
      f.routes['GET /api/v1/imports/google/browse'] = (req) {
        final inFolder = req.url.queryParameters['folder'] == 'g1';
        return http.Response(
            jsonEncode({
              'data': {
                'items': inFolder
                    ? [
                        {'id': 'g3', 'name': 'Inside.docx', 'mime_type': 'application/vnd.google-apps.document', 'web_view_link': 'https://docs.google.com/g3'}
                      ]
                    : [
                        {'id': 'g1', 'name': 'Plans', 'mime_type': 'application/vnd.google-apps.folder', 'is_folder': true},
                      ],
                'next_page_token': '',
              }
            }),
            200);
      };
      final launched = await pump(t, f);
      expect(find.text('Connected as me@gmail.com'), findsOneWidget);
      expect(find.text('Add from Google Drive'), findsOneWidget);

      await t.tap(find.text('Plans'));
      await t.pumpAndSettle();
      expect(f.calls.last.url.queryParameters['folder'], 'g1');
      expect(find.text('Inside.docx'), findsOneWidget);

      await t.tap(find.text('Inside.docx'));
      await t.pump();
      expect(launched.single.toString(), 'https://docs.google.com/g3');

      connectResult = const GoogleConnectResult(GoogleConnectStatus.cancelled);
      await t.tap(find.text('Add from Google Drive'));
      await t.pumpAndSettle();
      expect(connects, ['https://drive.test']);
      expect(launched, hasLength(1)); // still only the Google file
      expect(find.text('Inside.docx'), findsOneWidget); // cancelled: stays where it was
    });

    testWidgets('access expired while browsing → back to "connect"', (t) async {
      final f = _Fake()
        ..on('GET /api/v1/imports/google/connection', {'configured': true, 'connected': true})
        ..on('GET /api/v1/imports/google/browse', {
          'error': {'code': 'not_connected', 'message': 'Google Drive access expired — connect it again.'}
        }, status: 409);
      await pump(t, f);
      expect(find.text('Connect Google Drive'), findsOneWidget);
    });

    testWidgets('server without Google import says so', (t) async {
      final f = _Fake()..on('GET /api/v1/imports/google/connection', {'configured': false, 'connected': false});
      await pump(t, f);
      expect(find.textContaining('isn’t available on this server'), findsOneWidget);
      expect(find.text('Connect Google Drive'), findsNothing);
    });
  });

  testWidgets('notification bell: unread badge, list, mark all read', (t) async {
    final f = _Fake()
      ..on('GET /api/v1/notifications', {
        'items': [
          {'id': 'n1', 'kind': 'share', 'title': 'Ann shared “Budget.xlsx”', 'body': '', 'created_at': '2026-10-18T10:00:00Z'}
        ],
        'unread': 1,
      })
      ..on('POST /api/v1/notifications/read-all', {'ok': true});
    await t.pumpWidget(MaterialApp(home: Scaffold(appBar: AppBar(actions: [DriveNotificationBell(api: f.api())]))));
    await t.pumpAndSettle();
    expect(find.text('1'), findsOneWidget); // badge

    await t.tap(find.byTooltip('Notifications'));
    await t.pumpAndSettle();
    expect(find.text('Ann shared “Budget.xlsx”'), findsOneWidget);
    await t.tap(find.text('Mark all read'));
    await t.pumpAndSettle();
    expect(f.calls.any((r) => r.url.path == '/api/v1/notifications/read-all'), isTrue);
    expect(find.text('Mark all read'), findsNothing);

    // Leave no polling timer behind.
    await t.pumpWidget(const SizedBox());
  });
}
