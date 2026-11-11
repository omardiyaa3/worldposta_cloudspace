import 'dart:convert';

import 'package:cloudspace_app/screens/drive/drive_sync_folders.dart';
import 'package:cloudspace_app/services/drive/drive_api.dart';
import 'package:cloudspace_app/services/drive/drive_client.dart';
import 'package:cloudspace_app/services/drive/drive_sync_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _folder(String id, String name) => {'id': id, 'kind': 'folder', 'name': name};

void main() {
  testWidgets('unchecking a folder stops syncing it (and its subfolders follow)', (t) async {
    SharedPreferences.setMockInitialValues({});
    final api = DriveApi(DriveClient(
      baseUrl: 'https://drive.test',
      token: 'dk_test',
      httpClient: MockClient((req) async {
        final parent = req.url.queryParameters['parent'];
        final items = parent == 'root'
            ? [_folder('a', 'Archive'), _folder('p', 'Projects'), {'id': 'f', 'kind': 'file', 'name': 'top.txt'}]
            : parent == 'p'
                ? [_folder('o', 'Old')]
                : <Map<String, dynamic>>[];
        return http.Response(jsonEncode({'data': {'items': items}}), 200, headers: {'content-type': 'application/json'});
      }),
    ));
    final sync = DriveSyncService(api, 'acct');
    await t.pumpWidget(ChangeNotifierProvider.value(
      value: sync,
      child: MaterialApp(home: Builder(builder: (c) => Scaffold(body: Center(child: TextButton(
        onPressed: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => DriveSyncFolders(api: api))),
        child: const Text('open'),
      ))))),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();

    expect(find.text('Archive'), findsOneWidget);
    expect(find.text('top.txt'), findsNothing); // folders only

    // Expand Projects, uncheck Old: Projects becomes "partly synced".
    await t.tap(find.text('Projects'));
    await t.pumpAndSettle();
    expect(find.text('Old'), findsOneWidget);
    Checkbox box(String name) => t.widget<Checkbox>(find.descendant(
        of: find.ancestor(of: find.text(name), matching: find.byType(Row)).first, matching: find.byType(Checkbox)));
    await t.tap(find.descendant(
        of: find.ancestor(of: find.text('Old'), matching: find.byType(Row)).first, matching: find.byType(Checkbox)));
    await t.pump();
    expect(box('Old').value, isFalse);
    expect(box('Projects').value, isNull);

    // Uncheck Projects: it covers Old, whose box is now locked.
    await t.tap(find.descendant(
        of: find.ancestor(of: find.text('Projects'), matching: find.byType(Row)).first, matching: find.byType(Checkbox)));
    await t.pump();
    expect(box('Projects').value, isFalse);
    expect(box('Old').onChanged, isNull);

    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(sync.excludedFolders, {'Projects'});
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('sync_acct_excluded'), ['Projects']);
  });
}
