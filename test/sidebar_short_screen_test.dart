// The sidebar on short screens (landscape iPhone Duo, small iPad windows):
// no overflow, every item reachable, storage box never covering items.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:cloudspace_app/services/drive/drive_account.dart';
import 'package:cloudspace_app/services/drive/drive_account_manager.dart';
import 'package:cloudspace_app/widgets/drive_sidebar.dart';

class _MemTokens implements TokenStore {
  @override
  Future<String?> read(String id) async => null;
  @override
  Future<void> write(String id, String t) async {}
  @override
  Future<void> delete(String id) async {}
}

class _MemMeta implements AccountMetaStore {
  @override
  Future<List<Map<String, dynamic>>> loadAccounts() async => [];
  @override
  Future<void> saveAccounts(List<Map<String, dynamic>> m) async {}
  @override
  Future<String?> loadActiveId() async => null;
  @override
  Future<void> saveActiveId(String? id) async {}
}

Future<void> _pump(WidgetTester t, double height) async {
  // The test font draws every glyph as a full square, so "Posta Drive" is wider
  // than in the app; only overflow at the BOTTOM matters here.
  final previous = FlutterError.onError;
  FlutterError.onError = (d) {
    if (d.exceptionAsString().contains('overflowed') && d.toString().contains('on the right')) return;
    previous?.call(d);
  };
  addTearDown(() => FlutterError.onError = previous);
  t.view.physicalSize = const Size(800, 1200);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final mgr = DriveAccountManager(tokens: _MemTokens(), meta: _MemMeta(), validator: (_, __) async => throw UnimplementedError());
  await t.pumpWidget(ChangeNotifierProvider<DriveAccountManager>.value(
    value: mgr,
    child: MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            height: height,
            child: DriveSidebar(
              currentRoute: 'files', usedBytes: 1, totalBytes: 100,
              onNewPressed: () {}, onNavigate: (_) {}, showGoogleDrive: true,
            ),
          ),
        ),
      ),
    ),
  ));
}

void main() {
  testWidgets('short screen: everything scrolls together and the last item is reachable', (t) async {
    await _pump(t, 420); // shorter than the sidebar's content
    expect(t.takeException(), isNull, reason: 'no overflow');
    await t.scrollUntilVisible(find.text('Activity'), 100, scrollable: find.byType(Scrollable).first);
    expect(find.text('Activity').hitTestable(), findsOneWidget, reason: 'Activity must be reachable, not hidden under storage');
    expect(find.text('STORAGE'), findsOneWidget);
  });

  testWidgets('tall screen: storage box sits at the bottom', (t) async {
    await _pump(t, 1000);
    expect(t.takeException(), isNull);
    final storage = t.getTopLeft(find.text('STORAGE'));
    final activity = t.getTopLeft(find.text('Activity'));
    expect(storage.dy, greaterThan(activity.dy + 200), reason: 'pushed to the bottom, not right under the list');
  });

  testWidgets('landscape iPhone Duo (669 pt tall): everything fits without scrolling', (t) async {
    await _pump(t, 669);
    expect(t.takeException(), isNull);
    final pos = t.state<ScrollableState>(find.byType(Scrollable).first).position;
    expect(pos.maxScrollExtent, 0, reason: 'the storage box must not be pushed below the edge');
    expect(find.textContaining('used').hitTestable(), findsOneWidget);
  });
}
