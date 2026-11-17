import 'package:flutter_test/flutter_test.dart';
import 'package:cloudspace_app/services/drive/drive_api.dart';

void main() {
  test('file activity names who did it', () {
    final a = DriveActivity.fromJson({'id': 1, 'type': 'file.updated', 'actor_user_id': 'u2', 'actor_name': 'Sara Ali', 'actor_email': 's@a.com'});
    expect(a.describe('u1'), 'Sara Ali · Edited');
    expect(a.describe('u2'), 'You · Edited');
  });
  test('falls back to email, then to the action alone', () {
    expect(DriveActivity.fromJson({'id': 2, 'type': 'wopi.saved', 'actor_user_id': 'u3', 'actor_email': 'x@y.com'}).describe('u1'), 'x@y.com · Saved from Office');
    expect(DriveActivity.fromJson({'id': 3, 'type': 'share.accessed'}).describe('u1'), 'Opened the share link');
    expect(DriveActivity.fromJson({'id': 4, 'type': 'file.something_new'}).describe(null), 'Something new');
  });
}
