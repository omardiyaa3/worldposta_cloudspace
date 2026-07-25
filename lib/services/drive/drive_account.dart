// drive_account.dart — account model + persistence interfaces for the Drive.
//
// ISOLATION: an account IS a bound identity — one `dk_` token → one (tenant,
// user). The token is the whole credential. We keep tokens OUT of plaintext
// prefs (the old Nextcloud code stored app passwords in SharedPreferences):
// non-secret metadata goes to [AccountMetaStore], the token to [TokenStore]
// (backed by the OS keystore). Nothing here mixes two accounts' data.
//
// Pure Dart — the concrete Flutter-backed stores live in drive_account_stores.dart
// so this file (and the manager) stay unit-testable with in-memory fakes.

/// One signed-in Drive identity.
class DriveAccount {
  final String id; // local, stable key for this stored login
  final String serverUrl; // https://drive.worldposta.com (no trailing slash)
  final String token; // dk_… — the credential
  final String userId; // Drive user uuid
  final String tenantId; // Drive tenant uuid
  final String email;
  final String displayName;
  final bool isAdmin;

  const DriveAccount({
    required this.id,
    required this.serverUrl,
    required this.token,
    required this.userId,
    required this.tenantId,
    required this.email,
    required this.displayName,
    required this.isAdmin,
  });

  /// Non-secret metadata for [AccountMetaStore]. The token is deliberately
  /// excluded — it never lands in prefs.
  Map<String, dynamic> toMeta() => {
        'id': id,
        'serverUrl': serverUrl,
        'userId': userId,
        'tenantId': tenantId,
        'email': email,
        'displayName': displayName,
        'isAdmin': isAdmin,
      };

  /// Rebuild from stored metadata plus the token fetched from [TokenStore].
  factory DriveAccount.fromMeta(Map<String, dynamic> m, {required String token}) => DriveAccount(
        id: m['id'] as String,
        serverUrl: (m['serverUrl'] as String?) ?? '',
        token: token,
        userId: (m['userId'] as String?) ?? '',
        tenantId: (m['tenantId'] as String?) ?? '',
        email: (m['email'] as String?) ?? '',
        displayName: (m['displayName'] as String?) ?? (m['email'] as String?) ?? '',
        isAdmin: m['isAdmin'] == true,
      );

  DriveAccount copyWith({String? displayName, String? email, bool? isAdmin, String? token}) => DriveAccount(
        id: id,
        serverUrl: serverUrl,
        token: token ?? this.token,
        userId: userId,
        tenantId: tenantId,
        email: email ?? this.email,
        displayName: displayName ?? this.displayName,
        isAdmin: isAdmin ?? this.isAdmin,
      );

  /// Two logins collide when they are the same user on the same server.
  bool sameIdentityAs(DriveAccount other) =>
      serverUrl == other.serverUrl && userId == other.userId;
}

/// Secret store for per-account tokens (OS keystore in the app; in-memory in
/// tests). Keyed by account id so removing an account can wipe exactly its token.
abstract class TokenStore {
  Future<String?> read(String accountId);
  Future<void> write(String accountId, String token);
  Future<void> delete(String accountId);
}

/// Non-secret store for the account list and the active-account pointer.
abstract class AccountMetaStore {
  Future<List<Map<String, dynamic>>> loadAccounts();
  Future<void> saveAccounts(List<Map<String, dynamic>> metas);
  Future<String?> loadActiveId();
  Future<void> saveActiveId(String? id);
}
