import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cloudspace_app/config/layout.dart';

void main() {
  testWidgets('wide layout: unfolded iPhone Duo and iPads yes, iPhones in portrait no', (t) async {
    final widths = {
      'iPhone 17 Pro Max portrait': 440.0,
      'iPhone Duo folded (outer)': 466.0,
      'iPhone Duo unfolded (inner)': 669.0,
      'iPad mini portrait': 744.0,
    };
    final got = <String, bool>{};
    for (final e in widths.entries) {
      await t.pumpWidget(MediaQuery(
        data: MediaQueryData(size: Size(e.value, 900)),
        child: Builder(builder: (c) {
          got[e.key] = isWideLayout(c);
          return const SizedBox();
        }),
      ));
    }
    expect(got, {
      'iPhone 17 Pro Max portrait': false,
      'iPhone Duo folded (outer)': false,
      'iPhone Duo unfolded (inner)': true,
      'iPad mini portrait': true,
    });
  });
}
