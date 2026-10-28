// The real "Sign in" button: the in-app sign-in page must load and become
// usable (the "Loading sign-in…" overlay must go away). App Review was stuck
// on that overlay (macOS) / couldn't reach the server (iPad).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:cloudspace_app/main.dart' as app;

Future<bool> _waitGone(WidgetTester t, Finder f, int seconds) async {
  for (var i = 0; i < seconds * 5; i++) {
    await t.pump(const Duration(milliseconds: 200));
    if (f.evaluate().isEmpty) return true;
  }
  return false;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Sign in opens a usable sign-in page', (t) async {
    app.main(const []);
    final signIn = find.widgetWithText(ElevatedButton, 'Sign in');
    for (var i = 0; i < 100 && signIn.evaluate().isEmpty; i++) {
      await t.pump(const Duration(milliseconds: 200));
    }
    expect(signIn, findsOneWidget, reason: 'start signed out');
    await t.tap(signIn);
    await t.pump(const Duration(milliseconds: 500));

    final loading = find.text('Loading sign-in…');
    final unreachable = find.textContaining("Can't reach the Drive server");
    final gone = await _waitGone(t, loading, 30);
    stdout.writeln('overlay gone: $gone, unreachable error: ${unreachable.evaluate().isNotEmpty}');
    expect(unreachable, findsNothing, reason: 'server must be reachable');
    expect(gone, isTrue, reason: '"Loading sign-in…" must not stay on top of the page');
  });
}
