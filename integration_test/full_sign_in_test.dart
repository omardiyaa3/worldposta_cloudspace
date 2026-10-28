// The reviewer's path end to end: tap "Sign in", fill the Drive sign-in page
// inside the app with a real account, and land in the app.
//   flutter test integration_test/full_sign_in_test.dart -d <device> \
//     --dart-define=SIGNIN_EMAIL=… --dart-define=SIGNIN_PASSWORD=…
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:cloudspace_app/main.dart' as app;
import 'package:cloudspace_app/screens/auth/drive_sso_login_screen.dart';

const _email = String.fromEnvironment('SIGNIN_EMAIL');
const _password = String.fromEnvironment('SIGNIN_PASSWORD');

Future<bool> _until(WidgetTester t, bool Function() ok, int seconds) async {
  for (var i = 0; i < seconds * 5; i++) {
    await t.pump(const Duration(milliseconds: 200));
    if (ok()) return true;
  }
  return false;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('sign in through the in-app sign-in page', (t) async {
    expect(_email.isNotEmpty && _password.isNotEmpty, isTrue, reason: 'pass SIGNIN_EMAIL / SIGNIN_PASSWORD');
    app.main(const []);
    final signIn = find.widgetWithText(ElevatedButton, 'Sign in');
    expect(await _until(t, () => signIn.evaluate().isNotEmpty, 20), isTrue, reason: 'start signed out');
    await t.tap(signIn);

    // The page loads and the overlay goes away.
    expect(await _until(t, () => find.text('Loading sign-in…').evaluate().isEmpty, 30), isTrue,
        reason: 'stuck on "Loading sign-in…"');
    expect(find.textContaining("Couldn't open the sign-in page"), findsNothing);

    // Wait for the form, then fill it like a person would.
    final c = DriveSsoLoginScreen.debugController!;
    final ready = await () async {
      for (var i = 0; i < 40; i++) {
        final r = await c.evaluateJavascript(source: "!!document.getElementById('adlogin-email')");
        if (r == true) return true;
        await t.pump(const Duration(milliseconds: 500));
      }
      return false;
    }();
    expect(ready, isTrue, reason: 'sign-in form never appeared');
    await c.evaluateJavascript(source: '''
      (() => {
        const set = (el, v) => {
          Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, v);
          el.dispatchEvent(new Event('input', { bubbles: true }));
        };
        set(document.getElementById('adlogin-email'), ${jsonEncode(_email)});
        set(document.getElementById('adlogin-password'), ${jsonEncode(_password)});
        setTimeout(() => document.querySelector('form[aria-label="Sign in"] button[type=submit]').click(), 300);
      })();
    ''');

    // Signed in: the app's home appears.
    final home = find.text('Overview');
    expect(await _until(t, () => home.evaluate().isNotEmpty, 60), isTrue, reason: 'never reached the app after signing in');
  });
}
