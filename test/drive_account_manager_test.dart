// Isolation + lifecycle tests for DriveAccountManager, using in-memory fakes so
// no network or platform channels are needed. These lock the "each one only
// sees his stuff" guarantees at the client layer.

import 'package:flutter_test/flutter_test.dart';
import 'package:cloudspace_app/services/drive/drive_account.dart';
import 'package:cloudspace_app/services/drive/drive_account_manager.dart';
import 'package:cloudspace_app/services/drive/drive_api.dart';
import 'package:cloudspace_app/services/drive/drive_client.dart';

class _MemTokenStore implements TokenStore {
  final Map<String, String> _m = {};
  @override
  Future<String?> read(String id) async => _m[id];
  @override
  Future<void> write(String id, String token) async => _m[id] = token;
  @override
  Future<void> delete(String id) async => _m.remove(id);
  int get count => _m.length;
  bool has(String id) => _m.containsKey(id);
}

class _MemMetaStore implements AccountMetaStore {
  List<Map<String, dynamic>> _accts = [];
  String? _active;
  @override
  Future<List<Map<String, dynamic>>> loadAccounts() async => _accts;
  @override
  Future<void> saveAccounts(List<Map<String, dynamic>> metas) async => _accts = metas;
  @override
  Future<String?> loadActiveId() async => _active;
  @override
  Future<void> saveActiveId(String? id) async => _active = id;
}

/// Fake validator: maps a token to a fixed identity, no network.
AccountValidator _validatorFor(Map<String, DriveMe> table) {
  return (serverUrl, token) async {
    final me = table[token];
    if (me == null) {
      throw DriveException('unauthenticated', 'bad token', 401);
    }
    return me;
  };
}

void main() {
  final alice = DriveMe(
      id: 'user-alice', tenantId: 'tenant-A', email: 'alice@a.com', displayName: 'Alice', isAdmin: false);
  final bob = DriveMe(
      id: 'user-bob', tenantId: 'tenant-B', email: 'bob@b.com', displayName: 'Bob', isAdmin: true);
  final table = {'dk_alice': alice, 'dk_bob': bob};

  test('paste token adds an account and makes it active', () async {
    final mgr = DriveAccountManager(
      tokens: _MemTokenStore(),
      meta: _MemMetaStore(),
      validator: _validatorFor(table),
    );
    await mgr.init();
    expect(mgr.isLoggedIn, isFalse);

    final acct = await mgr.addAccountFromToken(serverUrl: 'https://d.example/', token: 'dk_alice');
    expect(mgr.isLoggedIn, isTrue);
    expect(acct.userId, 'user-alice');
    expect(acct.tenantId, 'tenant-A');
    expect(acct.serverUrl, 'https://d.example'); // trailing slash normalized
    expect(mgr.activeAccount!.email, 'alice@a.com');
  });

  test('an invalid token is rejected and adds nothing', () async {
    final tokens = _MemTokenStore();
    final mgr = DriveAccountManager(tokens: tokens, meta: _MemMetaStore(), validator: _validatorFor(table));
    await mgr.init();
    expect(
      () => mgr.addAccountFromToken(serverUrl: 'https://d.example', token: 'dk_bogus'),
      throwsA(isA<DriveException>()),
    );
    await Future<void>.delayed(Duration.zero);
    expect(mgr.accounts, isEmpty);
    expect(tokens.count, 0);
  });

  test('ISOLATION: each account gets its own token-bound api', () async {
    final mgr = DriveAccountManager(
        tokens: _MemTokenStore(), meta: _MemMetaStore(), validator: _validatorFor(table));
    await mgr.init();
    final a = await mgr.addAccountFromToken(serverUrl: 'https://d.example', token: 'dk_alice');
    final b = await mgr.addAccountFromToken(serverUrl: 'https://d.example', token: 'dk_bob');

    // Distinct identities, distinct bound clients, each carrying its own token.
    expect(a.id, isNot(b.id));
    expect(mgr.apiForAccount(a).client.token, 'dk_alice');
    expect(mgr.apiForAccount(b).client.token, 'dk_bob');

    // Active api follows the active account.
    expect(mgr.activeApi!.client.token, 'dk_bob'); // b was added last → active
    await mgr.switchAccount(a.id);
    expect(mgr.activeApi!.client.token, 'dk_alice');
  });

  test('ISOLATION: removing an account wipes its token and drops its api', () async {
    final tokens = _MemTokenStore();
    final mgr =
        DriveAccountManager(tokens: tokens, meta: _MemMetaStore(), validator: _validatorFor(table));
    await mgr.init();
    final a = await mgr.addAccountFromToken(serverUrl: 'https://d.example', token: 'dk_alice');
    final b = await mgr.addAccountFromToken(serverUrl: 'https://d.example', token: 'dk_bob');

    await mgr.removeAccount(a.id);
    expect(tokens.has(a.id), isFalse); // token gone from keystore
    expect(tokens.has(b.id), isTrue); // other account untouched
    expect(mgr.accounts.map((x) => x.id), [b.id]);
    expect(mgr.activeAccount!.id, b.id); // active re-pointed to survivor
  });

  test('re-adding the same identity refreshes in place (no duplicate)', () async {
    final mgr = DriveAccountManager(
        tokens: _MemTokenStore(), meta: _MemMetaStore(), validator: _validatorFor(table));
    await mgr.init();
    final a1 = await mgr.addAccountFromToken(serverUrl: 'https://d.example', token: 'dk_alice');
    final a2 = await mgr.addAccountFromToken(serverUrl: 'https://d.example', token: 'dk_alice');
    expect(mgr.accounts.length, 1);
    expect(a1.id, a2.id); // same stable id
  });

  test('tokens survive a restart via the stores; metadata carries no token', () async {
    final tokens = _MemTokenStore();
    final meta = _MemMetaStore();
    final mgr1 =
        DriveAccountManager(tokens: tokens, meta: meta, validator: _validatorFor(table));
    await mgr1.init();
    await mgr1.addAccountFromToken(serverUrl: 'https://d.example', token: 'dk_alice');

    // Persisted metadata must NOT contain the token.
    final savedMeta = await meta.loadAccounts();
    expect(savedMeta.single.containsKey('token'), isFalse);
    expect(savedMeta.single['userId'], 'user-alice');

    // Fresh manager over the same stores rehydrates the account + token.
    final mgr2 =
        DriveAccountManager(tokens: tokens, meta: meta, validator: _validatorFor(table));
    await mgr2.init();
    expect(mgr2.isLoggedIn, isTrue);
    expect(mgr2.activeApi!.client.token, 'dk_alice');
  });
}
