// drive_account_stores.dart — concrete persistence for Drive accounts.
//
// Tokens → flutter_secure_storage (OS keystore). Account metadata + the active
// pointer → SharedPreferences (non-secret only). Kept separate from the manager
// so the manager stays unit-testable with in-memory fakes.

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'drive_account.dart';

/// Per-account token store backed by the OS keystore, with a prefs fallback for
/// platforms/dev where secure storage is unavailable (mirrors the resilience of
/// the old AuthService, but only ever stores tokens — never a password).
class SecureTokenStore implements TokenStore {
  final FlutterSecureStorage _secure = const FlutterSecureStorage();
  bool _useSecure = true;

  String _key(String accountId) => 'drive_token_$accountId';

  @override
  Future<String?> read(String accountId) async {
    if (_useSecure) {
      try {
        return await _secure.read(key: _key(accountId));
      } catch (e) {
        debugPrint('SecureTokenStore read fell back to prefs: $e');
        _useSecure = false;
      }
    }
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key(accountId));
  }

  @override
  Future<void> write(String accountId, String token) async {
    if (_useSecure) {
      try {
        await _secure.write(key: _key(accountId), value: token);
        return;
      } catch (e) {
        debugPrint('SecureTokenStore write fell back to prefs: $e');
        _useSecure = false;
      }
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key(accountId), token);
  }

  @override
  Future<void> delete(String accountId) async {
    try {
      await _secure.delete(key: _key(accountId));
    } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(accountId));
  }
}

/// Account metadata + active pointer in SharedPreferences (no secrets).
class PrefsAccountMetaStore implements AccountMetaStore {
  static const _accountsKey = 'drive_accounts';
  static const _activeKey = 'drive_active_account';

  @override
  Future<List<Map<String, dynamic>>> loadAccounts() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_accountsKey);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list.cast<Map<String, dynamic>>();
    } catch (e) {
      debugPrint('PrefsAccountMetaStore: bad accounts json: $e');
      return [];
    }
  }

  @override
  Future<void> saveAccounts(List<Map<String, dynamic>> metas) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_accountsKey, jsonEncode(metas));
  }

  @override
  Future<String?> loadActiveId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_activeKey);
  }

  @override
  Future<void> saveActiveId(String? id) async {
    final prefs = await SharedPreferences.getInstance();
    if (id == null) {
      await prefs.remove(_activeKey);
    } else {
      await prefs.setString(_activeKey, id);
    }
  }
}
