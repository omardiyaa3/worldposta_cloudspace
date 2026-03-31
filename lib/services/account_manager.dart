import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Represents a single Nextcloud account with all credentials needed for API
/// access.
class Account {
  final String id;
  final String serverUrl;
  final String username;
  final String userId;
  final String appPassword;
  final String displayName;

  const Account({
    required this.id,
    required this.serverUrl,
    required this.username,
    required this.userId,
    required this.appPassword,
    required this.displayName,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'serverUrl': serverUrl,
        'username': username,
        'userId': userId,
        'appPassword': appPassword,
        'displayName': displayName,
      };

  factory Account.fromJson(Map<String, dynamic> json) => Account(
        id: json['id'] as String,
        serverUrl: json['serverUrl'] as String,
        username: json['username'] as String,
        userId: (json['userId'] as String?) ?? json['username'] as String,
        appPassword: json['appPassword'] as String,
        displayName: (json['displayName'] as String?) ?? json['username'] as String,
      );

  Account copyWith({
    String? serverUrl,
    String? username,
    String? userId,
    String? appPassword,
    String? displayName,
  }) =>
      Account(
        id: id,
        serverUrl: serverUrl ?? this.serverUrl,
        username: username ?? this.username,
        userId: userId ?? this.userId,
        appPassword: appPassword ?? this.appPassword,
        displayName: displayName ?? this.displayName,
      );
}

/// Manages multiple Nextcloud accounts.  Persists the account list and the
/// active-account selection in SharedPreferences.
///
/// Provides AuthService-compatible getters so that existing code that reads
/// serverUrl / username / basicAuth etc. can work unchanged.
class AccountManager extends ChangeNotifier {
  static const _accountsKey = 'accounts';
  static const _activeKey = 'active_account_id';

  List<Account> _accounts = [];
  String? _activeAccountId;

  // ── public getters ──────────────────────────────────────────────────────

  List<Account> get accounts => List.unmodifiable(_accounts);

  Account? get activeAccount =>
      _accounts.cast<Account?>().firstWhere(
            (a) => a!.id == _activeAccountId,
            orElse: () => null,
          );

  bool get isLoggedIn => activeAccount != null;

  // AuthService-compatible convenience getters (delegate to active account)
  String? get serverUrl => activeAccount?.serverUrl;
  String? get username => activeAccount?.username;
  String? get userId => activeAccount?.userId ?? activeAccount?.username;
  String? get appPassword => activeAccount?.appPassword;
  String? get displayName => activeAccount?.displayName;

  String get basicAuth {
    final a = activeAccount;
    if (a == null) return '';
    final credentials = base64Encode(utf8.encode('${a.username}:${a.appPassword}'));
    return 'Basic $credentials';
  }

  // ── persistence ─────────────────────────────────────────────────────────

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();

    // Load accounts
    final raw = prefs.getString(_accountsKey);
    if (raw != null) {
      try {
        final list = json.decode(raw) as List<dynamic>;
        _accounts = list
            .map((e) => Account.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (e) {
        debugPrint('AccountManager: failed to parse accounts: $e');
      }
    }

    // Load active account id
    _activeAccountId = prefs.getString(_activeKey);

    // If the stored active id no longer exists, fall back to first account
    if (_activeAccountId != null &&
        !_accounts.any((a) => a.id == _activeAccountId)) {
      _activeAccountId = _accounts.isNotEmpty ? _accounts.first.id : null;
    }

    // Migrate from legacy single-account AuthService storage
    if (_accounts.isEmpty) {
      await _migrateFromAuthService(prefs);
    }

    notifyListeners();
  }

  /// One-time migration: read the old AuthService keys and create an Account.
  Future<void> _migrateFromAuthService(SharedPreferences prefs) async {
    final serverUrl = prefs.getString('auth_server_url');
    final username = prefs.getString('auth_username');
    final appPassword = prefs.getString('auth_app_password');

    if (serverUrl != null && username != null && appPassword != null) {
      final displayName = prefs.getString('auth_display_name') ?? username;
      final userId = prefs.getString('auth_user_id') ?? username;

      final account = Account(
        id: const Uuid().v4(),
        serverUrl: serverUrl,
        username: username,
        userId: userId,
        appPassword: appPassword,
        displayName: displayName,
      );

      _accounts.add(account);
      _activeAccountId = account.id;
      await _persist();
      debugPrint('AccountManager: migrated legacy account for $username');
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _accountsKey,
      json.encode(_accounts.map((a) => a.toJson()).toList()),
    );
    if (_activeAccountId != null) {
      await prefs.setString(_activeKey, _activeAccountId!);
    } else {
      await prefs.remove(_activeKey);
    }
  }

  // ── account management ──────────────────────────────────────────────────

  Future<void> addAccount(Account account) async {
    // Prevent duplicate: same server + username
    final existing = _accounts.indexWhere(
      (a) => a.serverUrl == account.serverUrl && a.username == account.username,
    );
    if (existing >= 0) {
      // Update existing account instead of adding duplicate
      _accounts[existing] = account;
    } else {
      _accounts.add(account);
    }
    _activeAccountId = account.id;
    await _persist();
    notifyListeners();
  }

  Future<void> removeAccount(String accountId) async {
    _accounts.removeWhere((a) => a.id == accountId);
    if (_activeAccountId == accountId) {
      _activeAccountId = _accounts.isNotEmpty ? _accounts.first.id : null;
    }
    await _persist();
    notifyListeners();
  }

  Future<void> switchAccount(String accountId) async {
    if (!_accounts.any((a) => a.id == accountId)) return;
    _activeAccountId = accountId;
    await _persist();
    notifyListeners();
  }

  Future<void> updateAccount(Account account) async {
    final idx = _accounts.indexWhere((a) => a.id == account.id);
    if (idx >= 0) {
      _accounts[idx] = account;
      await _persist();
      notifyListeners();
    }
  }

  Future<void> logout(String accountId) async {
    await removeAccount(accountId);
  }

  /// Log out of the currently active account.
  Future<void> logoutCurrent() async {
    if (_activeAccountId != null) {
      await removeAccount(_activeAccountId!);
    }
  }
}
