// Smoke test: the login screen renders and the token sign-in validates input.
// (The full app can't be pumped headless — it needs window/tray/secure-storage
// plugins. Behavior is covered by drive_account_manager_test.dart + the live
// harness in tool/verify_drive.dart.)

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:cloudspace_app/services/drive/drive_account.dart';
import 'package:cloudspace_app/services/drive/drive_account_manager.dart';
import 'package:cloudspace_app/screens/auth/drive_login_screen.dart';

class _MemTokenStore implements TokenStore {
  final _m = <String, String>{};
  @override
  Future<String?> read(String id) async => _m[id];
  @override
  Future<void> write(String id, String t) async => _m[id] = t;
  @override
  Future<void> delete(String id) async => _m.remove(id);
}

class _MemMetaStore implements AccountMetaStore {
  @override
  Future<List<Map<String, dynamic>>> loadAccounts() async => [];
  @override
  Future<void> saveAccounts(List<Map<String, dynamic>> m) async {}
  @override
  Future<String?> loadActiveId() async => null;
  @override
  Future<void> saveActiveId(String? id) async {}
}

void main() {
  testWidgets('login screen renders and rejects a non-token', (tester) async {
    final mgr = DriveAccountManager(
      tokens: _MemTokenStore(),
      meta: _MemMetaStore(),
      validator: (_, __) async => throw Exception('should not be called'),
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<DriveAccountManager>.value(
        value: mgr,
        child: const MaterialApp(home: DriveLoginScreen()),
      ),
    );

    expect(find.text('Sign in with your work account.'), findsOneWidget);

    // Advanced token sign-in: something that isn't a dk_ token surfaces a
    // validation error without ever calling the (throwing) validator.
    // The form is taller than the test window: scroll each control into view.
    await tester.ensureVisible(find.text('Advanced: use an access token'));
    await tester.tap(find.text('Advanced: use an access token'));
    await tester.pump();
    // The token field comes after the email/password form.
    await tester.enterText(find.byType(TextField).last, 'not-a-token');
    await tester.ensureVisible(find.text('Sign in with token'));
    await tester.tap(find.text('Sign in with token'));
    await tester.pump();
    expect(find.textContaining('access token'), findsWidgets);
  });
}
