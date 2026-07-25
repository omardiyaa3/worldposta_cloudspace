// drive_account_manager.dart — multi-account state for the Drive.
//
// Replaces the old Nextcloud AuthService + AccountManager + AuthBridge trio.
// Holds the signed-in accounts, the active one, and a per-account [DriveApi] so
// every request is made with the correct account's token.
//
// ISOLATION ("each one only sees his stuff"):
//   • one DriveApi per account, each bound to that account's token — never a
//     shared/global credential;
//   • `activeApi` always reflects the active account; switching rebinds it;
//   • removing an account deletes its token from the keystore and drops its
//     cached DriveApi so nothing lingers;
//   • the server does the real enforcement (token → tenant → RLS). The client's
//     job is to never send the wrong token or surface a stale account's cache.

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'drive_account.dart';
import 'drive_api.dart';
import 'drive_client.dart';

/// Validates a (serverUrl, token) pair and returns the caller's profile.
/// Injectable so tests don't hit the network.
typedef AccountValidator = Future<DriveMe> Function(String serverUrl, String token);

class DriveAccountManager extends ChangeNotifier {
  final TokenStore _tokens;
  final AccountMetaStore _meta;
  final AccountValidator _validate;

  final List<DriveAccount> _accounts = [];
  String? _activeId;
  final Map<String, DriveApi> _apis = {}; // accountId → bound api
  bool _busy = false;

  DriveAccountManager({
    required TokenStore tokens,
    required AccountMetaStore meta,
    AccountValidator? validator,
  })  : _tokens = tokens,
        _meta = meta,
        _validate = validator ?? _defaultValidator;

  /// Default validator: bind a client to the token and read /me.
  static Future<DriveMe> _defaultValidator(String serverUrl, String token) {
    return DriveApi(DriveClient(baseUrl: serverUrl, token: token)).me();
  }

  // ── public state ───────────────────────────────────────────────────────────

  List<DriveAccount> get accounts => List.unmodifiable(_accounts);
  bool get isLoggedIn => activeAccount != null;
  bool get isBusy => _busy;

  DriveAccount? get activeAccount {
    for (final a in _accounts) {
      if (a.id == _activeId) return a;
    }
    return null;
  }

  /// The API for the active account, or null when signed out. Every screen
  /// should read Drive data through this so the active token is always used.
  DriveApi? get activeApi {
    final a = activeAccount;
    return a == null ? null : _apiFor(a);
  }

  /// The API bound to a specific account (used by per-account background sync).
  DriveApi apiForAccount(DriveAccount a) => _apiFor(a);

  DriveApi _apiFor(DriveAccount a) =>
      _apis[a.id] ??= DriveApi(DriveClient(baseUrl: a.serverUrl, token: a.token));

  // ── lifecycle ───────────────────────────────────────────────────────────────

  Future<void> init() async {
    final metas = await _meta.loadAccounts();
    _accounts.clear();
    for (final m in metas) {
      final id = m['id'] as String?;
      if (id == null) continue;
      final token = await _tokens.read(id);
      if (token == null || token.isEmpty) continue; // token gone → drop the login
      _accounts.add(DriveAccount.fromMeta(m, token: token));
    }
    _activeId = await _meta.loadActiveId();
    if (_activeId != null && !_accounts.any((a) => a.id == _activeId)) {
      _activeId = _accounts.isNotEmpty ? _accounts.first.id : null;
    }
    if (_activeId == null && _accounts.isNotEmpty) _activeId = _accounts.first.id;
    notifyListeners();
  }

  /// Validate a pasted token, then add (or refresh) the account and make it
  /// active. Throws [DriveException] if the token is invalid.
  Future<DriveAccount> addAccountFromToken({
    required String serverUrl,
    required String token,
  }) async {
    _busy = true;
    notifyListeners();
    try {
      final normalizedUrl =
          serverUrl.endsWith('/') ? serverUrl.substring(0, serverUrl.length - 1) : serverUrl;
      final me = await _validate(normalizedUrl, token);

      // Collision: same user on same server → refresh the existing login in place.
      final existingIdx =
          _accounts.indexWhere((a) => a.serverUrl == normalizedUrl && a.userId == me.id);
      final account = DriveAccount(
        id: existingIdx >= 0 ? _accounts[existingIdx].id : const Uuid().v4(),
        serverUrl: normalizedUrl,
        token: token,
        userId: me.id,
        tenantId: me.tenantId,
        email: me.email,
        displayName: me.displayName,
        isAdmin: me.isAdmin,
      );

      if (existingIdx >= 0) {
        _accounts[existingIdx] = account;
      } else {
        _accounts.add(account);
      }
      _apis.remove(account.id); // force a fresh client with the new token
      await _tokens.write(account.id, token);
      _activeId = account.id;
      await _persistMeta();
      notifyListeners();
      return account;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> switchAccount(String accountId) async {
    if (!_accounts.any((a) => a.id == accountId)) return;
    _activeId = accountId;
    await _meta.saveActiveId(accountId);
    notifyListeners();
  }

  /// Sign out of one account: wipe its token, drop its bound api, re-point active.
  Future<void> removeAccount(String accountId) async {
    _accounts.removeWhere((a) => a.id == accountId);
    _apis.remove(accountId);
    await _tokens.delete(accountId);
    if (_activeId == accountId) {
      _activeId = _accounts.isNotEmpty ? _accounts.first.id : null;
    }
    await _persistMeta();
    notifyListeners();
  }

  Future<void> logoutCurrent() async {
    if (_activeId != null) await removeAccount(_activeId!);
  }

  Future<void> _persistMeta() async {
    await _meta.saveAccounts(_accounts.map((a) => a.toMeta()).toList());
    await _meta.saveActiveId(_activeId);
  }

  @override
  void dispose() {
    _apis.clear();
    super.dispose();
  }
}
