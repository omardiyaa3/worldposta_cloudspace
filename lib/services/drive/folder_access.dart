// folder_access.dart — keeps the sandboxed macOS app's access to the user's
// chosen sync folder across launches (security-scoped bookmarks, see
// FolderAccess in macos/Runner/MainFlutterWindow.swift). No-op elsewhere.

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class FolderAccess {
  static const _channel = MethodChannel('posta/folder_access');

  static bool get _active => !kIsWeb && Platform.isMacOS;

  /// Bookmark for a folder the user just picked (null if not needed/failed).
  static Future<String?> bookmark(String path) async {
    if (!_active) return null;
    try {
      return await _channel.invokeMethod<String>('bookmark', path);
    } catch (e) {
      debugPrint('FolderAccess.bookmark failed: $e');
      return null;
    }
  }

  /// Re-opens a bookmarked folder for this run. Returns its current path and
  /// the (possibly refreshed) bookmark, or null if access can't be restored.
  static Future<({String path, String bookmark})?> resolve(String bookmark) async {
    if (!_active) return null;
    try {
      final r = await _channel.invokeMapMethod<String, String>('resolve', bookmark);
      if (r == null || r['path'] == null) return null;
      return (path: r['path']!, bookmark: r['bookmark'] ?? bookmark);
    } catch (e) {
      debugPrint('FolderAccess.resolve failed: $e');
      return null;
    }
  }
}
