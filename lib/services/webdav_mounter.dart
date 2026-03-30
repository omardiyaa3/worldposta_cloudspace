import 'dart:io';
import 'package:flutter/foundation.dart';
import 'auth_service.dart';

class WebDavMounter {
  static bool _isMounted = false;
  static String? _mountPath;

  static bool get isMounted => _isMounted;
  static String? get mountPath => _mountPath;

  static Future<void> mount(AuthService auth) async {
    if (_isMounted) return;
    if (auth.serverUrl == null || auth.userId == null) return;

    try {
      final host = Uri.parse(auth.serverUrl!).host;
      final user = auth.username ?? '';
      final pass = auth.appPassword ?? '';
      final userId = auth.userId ?? '';

      if (Platform.isMacOS) {
        // Step 1: Store credentials in macOS Keychain so mount doesn't ask
        await Process.run('security', [
          'add-internet-password',
          '-a', user,
          '-s', host,
          '-p', '443',
          '-r', 'htps',
          '-l', 'CloudSpace',
          '-w', pass,
          '-U', // Update if exists
        ]);
        debugPrint('Keychain credentials stored for $user@$host');

        // Step 2: Mount via osascript (Finder Connect to Server) — silently
        final webdavUrl = 'https://$host/remote.php/dav/files/$userId/';
        final result = await Process.run('osascript', [
          '-e', 'mount volume "$webdavUrl" as user name "$user" with password "$pass"',
        ]);
        debugPrint('Mount result: exit=${result.exitCode} stdout=${result.stdout} stderr=${result.stderr}');

        if (result.exitCode == 0) {
          _isMounted = true;
          // Find the mount point — it's usually /Volumes/dav or /Volumes/userId
          final mountResult = await Process.run('mount', []);
          final lines = mountResult.stdout.toString().split('\n');
          for (final line in lines) {
            if (line.contains(host) && line.contains('/Volumes/')) {
              final parts = line.split(' on ');
              if (parts.length > 1) {
                _mountPath = parts[1].split(' (')[0].trim();
                debugPrint('Found mount at: $_mountPath');
              }
            }
          }
        }
      } else if (Platform.isWindows) {
        final webdavUrl = 'https://$host/remote.php/dav/files/$userId/';
        final winUrl = webdavUrl.replaceFirst('https://', '\\\\').replaceAll('/', '\\');
        await Process.run('net', ['use', 'Z:', winUrl, '/user:$user', pass]);
        _isMounted = true;
        _mountPath = 'Z:';
      } else if (Platform.isLinux) {
        final webdavUrl = 'davs://${Uri.encodeComponent(user)}:${Uri.encodeComponent(pass)}@$host/remote.php/dav/files/$userId/';
        await Process.run('gio', ['mount', webdavUrl]);
        _isMounted = true;
      }
    } catch (e) {
      debugPrint('Mount failed: $e');
    }
  }

  static Future<void> unmount() async {
    if (!_isMounted) return;

    try {
      if (Platform.isMacOS) {
        if (_mountPath != null) {
          await Process.run('umount', [_mountPath!]);
          debugPrint('Unmounted $_mountPath');
        }
      } else if (Platform.isWindows) {
        await Process.run('net', ['use', 'Z:', '/delete', '/yes']);
      } else if (Platform.isLinux) {
        await Process.run('gio', ['mount', '-u', 'davs://cloudspace.worldposta.com/']);
      }
    } catch (e) {
      debugPrint('Unmount failed: $e');
    }
    _isMounted = false;
    _mountPath = null;
  }
}
