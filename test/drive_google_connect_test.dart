import 'package:cloudspace_app/services/drive/drive_google_connect.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the browser sheet callback says how it ended', () {
    GoogleConnectResult r(String u) => GoogleConnectResult.fromCallback(Uri.parse(u));
    expect(r('postadrive://google?status=picked&count=3').status, GoogleConnectStatus.picked);
    expect(r('postadrive://google?status=picked&count=3').count, 3);
    expect(r('http://127.0.0.1:5000/google?status=connected').status, GoogleConnectStatus.connected);
    expect(r('postadrive://google?status=cancelled').status, GoogleConnectStatus.cancelled);
    expect(r('postadrive://google?status=error').status, GoogleConnectStatus.error);
    expect(r('postadrive://google').status, GoogleConnectStatus.error);
  });
}
