// App Store screenshots: signs in with a token and walks the real screens.
//
//   flutter test integration_test/store_screenshots_test.dart -d <device> \
//     --dart-define=SHOT_TOKEN=dk_…
//
// iOS: for each shot the test drops a request file in the app's tmp dir and
// waits; tool/store_shots.sh takes a real simulator screenshot (with status
// bar) and deletes the file. macOS: the app captures its own window.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:window_manager/window_manager.dart';

import 'package:cloudspace_app/config/layout.dart';
import 'package:cloudspace_app/main.dart' as app;

const _token = String.fromEnvironment('SHOT_TOKEN');

Future<void> _wait(WidgetTester t, Finder f, {int seconds = 30}) async {
  for (var i = 0; i < seconds * 5; i++) {
    await t.pump(const Duration(milliseconds: 200));
    if (f.evaluate().isNotEmpty) return;
  }
  await _shot(t, 'timeout_${DateTime.now().millisecondsSinceEpoch}');
  throw StateError('timed out waiting for $f');
}

Future<void> _idle(WidgetTester t, [int ms = 2500]) async {
  for (var i = 0; i < ms ~/ 100; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _shot(WidgetTester t, String name) async {
  await _idle(t);
  if (Platform.isMacOS) {
    final view = t.binding.renderViews.first;
    final layer = view.debugLayer! as OffsetLayer;
    final img = await layer.toImage(view.paintBounds); // paintBounds is already in device pixels
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    await File('${Directory.systemTemp.path}/$name.png').writeAsBytes(png!.buffer.asUint8List());
    return;
  }
  final req = File('${Directory.systemTemp.path}/shot_request_$name');
  await req.writeAsString(name);
  for (var i = 0; i < 300 && req.existsSync(); i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
  if (req.existsSync()) throw StateError('nobody took screenshot $name');
}

Finder _text(String s) => find.text(s, skipOffstage: true);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('store screenshots', (t) async {
    expect(_token, isNotEmpty, reason: 'pass --dart-define=SHOT_TOKEN=dk_…');
    app.main(const []);
    if (Platform.isMacOS) {
      await _idle(t, 1500);
      await windowManager.setSize(const Size(1280, 832)); // 1280×800 of content → 2560×1600 on Retina (fits a laptop screen)
      await windowManager.center();
    }
    final login = find.text('Advanced: use an access token');
    final home = _text('Overview'); // visible on every screen size (the Recent list can be below the fold)
    await _wait(t, find.byWidgetPredicate((_) => login.evaluate().isNotEmpty || home.evaluate().isNotEmpty));
    if (login.evaluate().isNotEmpty) {
      await t.tap(login);
      await t.pump();
      await t.enterText(find.byType(TextField).last, _token);
      await t.tap(find.text('Sign in with token'));
    }
    await _wait(t, home, seconds: 45);
    await _shot(t, '1_home');

    final wide = t.binding.renderViews.first.size.width >= kWideLayoutWidth; // the app's own switch
    await t.tap(_text(wide ? 'My Drive' : 'Files').last);
    await _wait(t, _text('Projects'));
    await _shot(t, '2_my_drive');

    await t.tap(_text('Projects').last);
    await _wait(t, _text('Website Redesign Brief.docx'));
    await _shot(t, '3_folder');

    // The ⋯ menu of a file.
    final row = find.ancestor(of: _text('Website Redesign Brief.docx'), matching: find.byType(InkWell)).first;
    final more = find.descendant(of: find.ancestor(of: row, matching: find.byType(Row)).first, matching: find.byIcon(Icons.more_horiz));
    await t.tap(more.evaluate().isNotEmpty ? more.first : find.byIcon(Icons.more_horiz).first);
    await _wait(t, _text('Share'));
    await _shot(t, '4_file_menu');

    await t.tap(_text('Share').last);
    await _wait(t, find.textContaining('Share', skipOffstage: true));
    await _idle(t, 3000);
    await _shot(t, '5_share');
  });
}
