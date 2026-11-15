import 'package:cloudspace_app/services/reserved_region.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the iPhone Duo bubble (starts in the status bar) is used', () {
    final r = ReservedTopRegion.fromMap({'left': 300.0, 'top': 0.0, 'right': 398.0, 'bottom': 70.0, 'systemTop': 24.0});
    expect(r, isNotNull);
    expect(r!.rect.bottom, 70);
  });

  test('a floating call window below the status bar is ignored', () {
    final r = ReservedTopRegion.fromMap({'left': 870.0, 'top': 32.0, 'right': 1096.0, 'bottom': 158.0, 'systemTop': 24.0});
    expect(r, isNull);
  });

  test('nothing reported → no region', () {
    expect(ReservedTopRegion.fromMap(null), isNull);
    expect(ReservedTopRegion.fromMap({}), isNull);
  });
}
