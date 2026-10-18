import 'package:flutter_test/flutter_test.dart';
import 'package:cloudspace_app/screens/drive/drive_share_sheet.dart';
import 'package:cloudspace_app/services/drive/drive_api.dart';

DrivePermission perm(String id, String user, {String role = 'viewer', String? from}) => DrivePermission.fromJson({
      'id': id,
      'resource_id': 'f1',
      'subject': {'type': 'user', 'id': user},
      'role': role,
      if (from != null) 'inherited_from': from,
    });

void main() {
  test('the owner is listed once, by their own grant, not again as inherited', () {
    final list = accessListWithoutRepeats([
      perm('p1', 'owner', role: 'owner'),
      perm('p2', 'owner', role: 'owner', from: 'folderA'),
      perm('p3', 'sara', from: 'folderA'),
      perm('p4', 'karim', role: 'editor'),
    ]);
    expect(list.map((p) => p.id), ['p1', 'p3', 'p4']);
  });

  test('someone inherited from two parents is listed once', () {
    final list = accessListWithoutRepeats([perm('a', 'sara', from: 'x'), perm('b', 'sara', from: 'y')]);
    expect(list.map((p) => p.id), ['a']);
  });
}
