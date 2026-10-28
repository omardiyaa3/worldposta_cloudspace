// http_client.dart — the HTTP client every Drive request goes through.
//
// iPhone, iPad and Mac use Apple's own networking (NSURLSession via
// cupertino_http): it handles IPv6-only (NAT64) networks — which App Review
// uses — system proxies, VPNs and the system's certificate trust, where
// dart:io's sockets can fail before reaching the server. Elsewhere, dart:io.

import 'dart:io' show Platform;

import 'package:cupertino_http/cupertino_http.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

http.Client newDriveHttpClient() {
  // `flutter test` runs as a plain host process without the native library.
  final underTest = !kIsWeb && Platform.environment.containsKey('FLUTTER_TEST');
  if (!kIsWeb && !underTest && (Platform.isIOS || Platform.isMacOS)) {
    final config = URLSessionConfiguration.ephemeralSessionConfiguration()
      ..timeoutIntervalForRequest = const Duration(seconds: 30)
      ..waitsForConnectivity = false;
    return CupertinoClient.fromSessionConfiguration(config);
  }
  return http.Client();
}
