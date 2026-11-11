// drive_api.dart — typed WorldPosta Drive API surface.
//
// The single service the app calls for every Drive operation. It wraps a
// [DriveClient] (which is bound to one account's token) and returns typed
// models. This replaces the old Nextcloud WebDavService. Endpoint paths and
// shapes mirror the Go backend exactly (internal/interfaces/http/*).
//
// Pure Dart (http only) so it is unit-testable against a live backend without
// Flutter.

import 'dart:typed_data';
import '../../models/drive_file.dart';
import 'drive_client.dart';

/// The authenticated caller's profile (GET /api/v1/me).
class DriveMe {
  final String id; // user uuid
  final String tenantId;
  final String email;
  final String displayName;
  final bool isAdmin;
  const DriveMe({
    required this.id,
    required this.tenantId,
    required this.email,
    required this.displayName,
    required this.isAdmin,
  });

  factory DriveMe.fromJson(Map<String, dynamic> j) => DriveMe(
        id: j['id'] as String,
        tenantId: (j['tenant_id'] as String?) ?? '',
        email: (j['email'] as String?) ?? '',
        displayName: (j['display_name'] as String?) ?? (j['email'] as String?) ?? '',
        isAdmin: j['is_admin'] == true,
      );
}

/// Storage usage (GET /api/v1/quota).
class DriveQuota {
  final int usedBytes;
  final int limitBytes; // -1 / 0 → unlimited
  final List<QuotaBucket> buckets; // by mime category
  final List<DriveFile> topLargest;
  const DriveQuota({
    required this.usedBytes,
    required this.limitBytes,
    required this.buckets,
    required this.topLargest,
  });

  factory DriveQuota.fromJson(Map<String, dynamic> j) => DriveQuota(
        usedBytes: (j['used_bytes'] as num?)?.toInt() ?? 0,
        limitBytes: (j['limit_bytes'] as num?)?.toInt() ?? -1,
        buckets: ((j['buckets'] as List?) ?? [])
            .map((e) => QuotaBucket.fromJson(e as Map<String, dynamic>))
            .toList(),
        topLargest: ((j['top'] as List?) ?? [])
            .map((e) => DriveFile(
                  id: e['id'] as String,
                  isDirectory: false,
                  name: (e['name'] as String?) ?? '',
                  sizeBytes: (e['bytes'] as num?)?.toInt() ?? 0,
                ))
            .toList(),
      );

  bool get isUnlimited => limitBytes <= 0;
}

class QuotaBucket {
  final String category;
  final int bytes;
  final int count;
  const QuotaBucket({required this.category, required this.bytes, required this.count});
  factory QuotaBucket.fromJson(Map<String, dynamic> j) => QuotaBucket(
        category: (j['category'] as String?) ?? 'other',
        bytes: (j['bytes'] as num?)?.toInt() ?? 0,
        count: (j['count'] as num?)?.toInt() ?? 0,
      );
}

/// A public share link (POST/GET /api/v1/shares).
class DriveShare {
  final String id;
  final String resourceId;
  final String token;
  final String url;
  final bool hasPassword;
  final bool allowDownload;
  final String permission; // viewer|commenter|editor
  final DateTime? expiresAt;
  const DriveShare({
    required this.id,
    required this.resourceId,
    required this.token,
    required this.url,
    required this.hasPassword,
    required this.allowDownload,
    required this.permission,
    this.expiresAt,
  });

  factory DriveShare.fromJson(Map<String, dynamic> j) => DriveShare(
        id: j['id'] as String,
        resourceId: (j['resource_id'] as String?) ?? '',
        token: (j['token'] as String?) ?? '',
        url: (j['url'] as String?) ?? '',
        hasPassword: j['has_password'] == true,
        allowDownload: j['allow_download'] != false,
        permission: (j['permission'] as String?) ?? 'viewer',
        expiresAt: j['expires_at'] is String ? DateTime.tryParse(j['expires_at'] as String) : null,
      );
}

/// A direct permission grant to a user/group (GET/POST /api/v1/permissions).
class DrivePermission {
  final String id;
  final String resourceId;
  final String subjectType; // user | group | external_tenant_user (pending email invite)
  final String subjectId;
  final String? subjectEmail;
  final String? subjectName;
  final DriveRole role;
  final String? inheritedFrom;
  final DateTime? expiresAt;
  final bool blockReshare;
  /// Recipient is outside the owner's organization (or a pending invite).
  final bool external;
  /// Email invite to someone who hasn't signed in to Drive yet.
  final bool pending;
  const DrivePermission({
    required this.id,
    required this.resourceId,
    required this.subjectType,
    required this.subjectId,
    this.subjectEmail,
    this.subjectName,
    required this.role,
    this.inheritedFrom,
    this.expiresAt,
    this.blockReshare = false,
    this.external = false,
    this.pending = false,
  });

  bool get isInherited => inheritedFrom != null && inheritedFrom!.isNotEmpty;

  factory DrivePermission.fromJson(Map<String, dynamic> j) {
    final subj = (j['subject'] as Map?) ?? const {};
    return DrivePermission(
      id: j['id'] as String,
      resourceId: (j['resource_id'] as String?) ?? '',
      subjectType: (subj['type'] as String?) ?? 'user',
      subjectId: (subj['id'] as String?) ?? '',
      subjectEmail: j['subject_email'] as String?,
      subjectName: j['subject_name'] as String?,
      role: DriveRoleX.fromWire(j['role'] as String?) ?? DriveRole.viewer,
      inheritedFrom: j['inherited_from'] as String?,
      expiresAt: j['expires_at'] is String ? DateTime.tryParse(j['expires_at'] as String) : null,
      blockReshare: j['block_reshare'] == true,
      external: j['external'] == true,
      pending: j['pending'] == true,
    );
  }
}

/// A directory hit from GET /api/v1/users/search (share picker).
class DriveUser {
  final String id;
  final String email;
  final String displayName;
  const DriveUser({required this.id, required this.email, required this.displayName});
  factory DriveUser.fromJson(Map<String, dynamic> j) => DriveUser(
        id: j['id'] as String,
        email: (j['email'] as String?) ?? '',
        displayName: (j['display_name'] as String?) ?? (j['email'] as String?) ?? '',
      );
}

/// A search hit (GET /api/v1/search) — a lighter shape than DriveFile.
class DriveSearchHit {
  final String id;
  final String name;
  final bool isDirectory;
  final String mimeType;
  final int sizeBytes;
  final String snippet;
  const DriveSearchHit({
    required this.id,
    required this.name,
    required this.isDirectory,
    required this.mimeType,
    required this.sizeBytes,
    required this.snippet,
  });
  factory DriveSearchHit.fromJson(Map<String, dynamic> j) => DriveSearchHit(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? '',
        isDirectory: (j['kind'] as String?) == 'folder',
        mimeType: (j['mime_type'] as String?) ?? '',
        sizeBytes: (j['size_bytes'] as num?)?.toInt() ?? 0,
        snippet: (j['snippet'] as String?) ?? '',
      );
}

/// A change event from GET /api/v1/changes (sync delta feed).
class DriveChange {
  final int seq;
  final String type; // file.created, file.deleted, file.moved, …
  final String? resourceType;
  final String? resourceId;
  final String? actorUserId;
  final DateTime? occurredAt;
  final Map<String, dynamic> data;
  const DriveChange({
    required this.seq,
    required this.type,
    this.resourceType,
    this.resourceId,
    this.actorUserId,
    this.occurredAt,
    this.data = const {},
  });
  factory DriveChange.fromJson(Map<String, dynamic> j) => DriveChange(
        seq: (j['seq'] as num?)?.toInt() ?? 0,
        type: (j['type'] as String?) ?? '',
        resourceType: j['resource_type'] as String?,
        resourceId: j['resource_id'] as String?,
        actorUserId: j['actor_user_id'] as String?,
        occurredAt: j['occurred_at'] is String ? DateTime.tryParse(j['occurred_at'] as String) : null,
        data: (j['data'] as Map?)?.cast<String, dynamic>() ?? const {},
      );
}

/// A page of changes plus the cursor to resume from.
class DriveChangePage {
  final List<DriveChange> items;
  final String nextCursor; // "" when caught up
  const DriveChangePage(this.items, this.nextCursor);
}

/// A user-facing activity row (GET /api/v1/me/activity).
class DriveActivity {
  final String id;
  final String action;
  final String? resourceId;
  final String? resourceType;
  final String outcome;
  final DateTime? occurredAt;
  const DriveActivity({
    required this.id,
    required this.action,
    this.resourceId,
    this.resourceType,
    required this.outcome,
    this.occurredAt,
  });
  factory DriveActivity.fromJson(Map<String, dynamic> j) => DriveActivity(
        id: j['id'].toString(),
        // /me/activity uses "action"; per-file /files/{id}/activity uses "type".
        action: (j['action'] as String?) ?? (j['type'] as String?) ?? '',
        resourceId: j['resource_id'] as String?,
        resourceType: j['resource_type'] as String?,
        outcome: (j['outcome'] as String?) ?? '',
        occurredAt: j['occurred_at'] is String ? DateTime.tryParse(j['occurred_at'] as String) : null,
      );
}

/// A stored version of a file (GET /files/{id}/versions).
class DriveVersion {
  final String id;
  final int sizeBytes;
  final String mimeType;
  final DateTime? createdAt;
  final bool isCurrent;
  final String? label;
  const DriveVersion({
    required this.id,
    required this.sizeBytes,
    required this.mimeType,
    this.createdAt,
    required this.isCurrent,
    this.label,
  });
  factory DriveVersion.fromJson(Map<String, dynamic> j) => DriveVersion(
        id: j['id'] as String,
        sizeBytes: (j['size_bytes'] as num?)?.toInt() ?? 0,
        mimeType: (j['mime_type'] as String?) ?? '',
        createdAt: j['created_at'] is String ? DateTime.tryParse(j['created_at'] as String) : null,
        isCurrent: j['is_current'] == true,
        label: j['label'] as String?,
      );
}

/// A comment on a file (GET /files/{id}/comments).
class DriveComment {
  final String id;
  final String authorName;
  final String body;
  final bool isExternal;
  final DateTime? createdAt;
  const DriveComment({
    required this.id,
    required this.authorName,
    required this.body,
    this.isExternal = false,
    this.createdAt,
  });
  factory DriveComment.fromJson(Map<String, dynamic> j) => DriveComment(
        id: j['id'] as String,
        authorName: (j['author_name'] as String?) ?? 'Someone',
        body: (j['body'] as String?) ?? '',
        isExternal: j['is_external'] == true,
        createdAt: j['created_at'] is String ? DateTime.tryParse(j['created_at'] as String) : null,
      );
}

/// A user tag (GET /api/v1/tags, /files/{id}/tags).
class DriveTag {
  final String id;
  final String name;
  final String color; // CSS colour, e.g. "#4f46e5"
  const DriveTag({required this.id, required this.name, required this.color});
  factory DriveTag.fromJson(Map<String, dynamic> j) => DriveTag(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? '',
        color: (j['color'] as String?) ?? '',
      );
}

/// An in-app notification (GET /api/v1/notifications).
class DriveNotification {
  final String id;
  final String kind; // share, comment, mention, …
  final String title;
  final String body;
  final String? resourceId;
  final DateTime? createdAt;
  final bool read;
  const DriveNotification({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    this.resourceId,
    this.createdAt,
    this.read = false,
  });
  factory DriveNotification.fromJson(Map<String, dynamic> j) => DriveNotification(
        id: j['id'] as String,
        kind: (j['kind'] as String?) ?? '',
        title: (j['title'] as String?) ?? '',
        body: (j['body'] as String?) ?? '',
        resourceId: j['resource_id'] as String?,
        createdAt: j['created_at'] is String ? DateTime.tryParse(j['created_at'] as String) : null,
        read: j['read_at'] is String,
      );
  DriveNotification markedRead() => DriveNotification(
      id: id, kind: kind, title: title, body: body, resourceId: resourceId, createdAt: createdAt, read: true);
}

/// The caller's Google Drive connection (GET /api/v1/imports/google/connection).
class GoogleConnection {
  final bool configured; // the server has Google import set up
  final bool connected; // this user connected their Google account
  final String? email;
  const GoogleConnection({required this.configured, required this.connected, this.email});
  factory GoogleConnection.fromJson(Map<String, dynamic> j) => GoogleConnection(
        configured: j['configured'] == true,
        connected: j['connected'] == true,
        email: j['email'] as String?,
      );
}

/// One Google Drive item the user gave Posta Drive access to
/// (GET /api/v1/imports/google/browse).
class GoogleItem {
  final String id;
  final String name;
  final String mimeType;
  final int size;
  final DateTime? modifiedAt;
  final bool isFolder;
  final String webViewLink;
  const GoogleItem({
    required this.id,
    required this.name,
    required this.mimeType,
    required this.size,
    this.modifiedAt,
    required this.isFolder,
    required this.webViewLink,
  });
  factory GoogleItem.fromJson(Map<String, dynamic> j) {
    final id = j['id'] as String;
    final link = j['web_view_link'] as String?;
    return GoogleItem(
      id: id,
      name: (j['name'] as String?) ?? '',
      mimeType: (j['mime_type'] as String?) ?? '',
      size: j['size'] is num ? (j['size'] as num).toInt() : int.tryParse('${j['size'] ?? ''}') ?? 0,
      modifiedAt: j['modified_at'] is String ? DateTime.tryParse(j['modified_at'] as String) : null,
      isFolder: j['is_folder'] == true,
      // Older servers don't send the link; Google's open URL works for any id.
      webViewLink: (link != null && link.isNotEmpty) ? link : 'https://drive.google.com/open?id=$id',
    );
  }
}

/// A page of Google items plus the token for the next page ("" = last page).
class GooglePage {
  final List<GoogleItem> items;
  final String nextPageToken;
  const GooglePage(this.items, this.nextPageToken);
}

/// Export targets per source extension — same table as the web
/// (fileMenuParts.tsx EXPORT_TARGETS_BY_EXT): what Collabora can convert to.
const Map<String, List<String>> driveExportTargets = {
  'doc': ['pdf', 'docx', 'odt', 'html', 'txt'],
  'docx': ['pdf', 'odt', 'html', 'txt'],
  'rtf': ['pdf', 'docx', 'odt', 'html', 'txt'],
  'odt': ['pdf', 'docx', 'html', 'txt'],
  'txt': ['pdf', 'docx', 'odt', 'html'],
  'html': ['pdf', 'docx', 'odt', 'txt'],
  'htm': ['pdf', 'docx', 'odt', 'txt'],
  'md': ['pdf', 'docx', 'odt', 'html', 'txt'],
  'xls': ['pdf', 'xlsx', 'html'],
  'xlsx': ['pdf', 'html'],
  'ods': ['pdf', 'xlsx', 'html'],
  'csv': ['pdf', 'xlsx', 'html'],
  'ppt': ['pdf', 'pptx', 'html'],
  'pptx': ['pdf', 'html'],
  'odp': ['pdf', 'pptx', 'html'],
  'pdf': ['docx', 'odt'],
};

const Map<String, String> driveExportLabels = {
  'pdf': 'PDF (.pdf)',
  'docx': 'Word (.docx)',
  'xlsx': 'Excel (.xlsx)',
  'pptx': 'PowerPoint (.pptx)',
  'odt': 'OpenDocument (.odt)',
  'html': 'HTML (.html)',
  'txt': 'Plain text (.txt)',
};

/// Formats a file can be exported to (empty → no "Export as").
List<String> driveExportTargetsFor(DriveFile f) =>
    f.isDirectory ? const [] : (driveExportTargets[f.extension] ?? const []);

/// Typed Drive API. One instance per account (wraps that account's client).
class DriveApi {
  final DriveClient _c;
  DriveApi(this._c);

  DriveClient get client => _c;

  // ── helpers ────────────────────────────────────────────────────────────────

  List<DriveFile> _items(dynamic data) =>
      (((data as Map?)?['items'] as List?) ?? const [])
          .map((e) => DriveFile.fromJson(e as Map<String, dynamic>))
          .toList();

  // ── identity / quota ─────────────────────────────────────────────────────

  Future<DriveMe> me() async => DriveMe.fromJson((await _c.get('/api/v1/me')) as Map<String, dynamic>);

  Future<DriveQuota> quota() async =>
      DriveQuota.fromJson((await _c.get('/api/v1/quota')) as Map<String, dynamic>);

  // ── browse ────────────────────────────────────────────────────────────────

  /// List a folder's children. [parentId] null → drive root.
  Future<List<DriveFile>> listFiles({String? parentId, int limit = 200, int offset = 0}) async {
    final data = await _c.get('/api/v1/files', query: {
      'parent': parentId ?? 'root',
      'limit': limit,
      'offset': offset,
    });
    return _items(data);
  }

  /// Breadcrumb ancestry for an item (root-visible ancestor → item).
  Future<List<DrivePathNode>> filePath(String id) async {
    // This endpoint breaks the envelope: {"path":[…]} at top level, so
    // DriveClient returns the whole map (no `data` key).
    final data = await _c.get('/api/v1/files/$id/path');
    final list = (data as Map?)?['path'] as List? ?? const [];
    return list.map((e) => DrivePathNode.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<DriveFile> fileDetail(String id) async =>
      DriveFile.fromJson((await _c.get('/api/v1/files/$id')) as Map<String, dynamic>);

  // ── mutate ────────────────────────────────────────────────────────────────

  Future<DriveFile> createFolder(String name, {String? parentId}) async {
    final data = await _c.post('/api/v1/folders', body: {
      'name': name,
      if (parentId != null) 'parent_id': parentId,
    });
    return DriveFile.fromJson(data as Map<String, dynamic>);
  }

  /// Create an empty Office/text doc. [kind] ∈ docx|xlsx|pptx|drawio|md|txt|json|yaml|csv.
  Future<DriveFile> createFile(String kind, {String? name, String? parentId}) async {
    final data = await _c.post('/api/v1/files/new', body: {
      'kind': kind,
      if (name != null) 'name': name,
      if (parentId != null) 'parent_id': parentId,
    });
    return DriveFile.fromJson(data as Map<String, dynamic>);
  }

  Future<void> rename(String id, String newName) async =>
      _c.patch('/api/v1/files/$id', body: {'name': newName});

  /// Move to [parentId] (null → root) and/or rename. Sends explicit null to move
  /// to root; omits parent_id when only renaming would be intended — but callers
  /// generally pass parentId explicitly.
  Future<void> move(String id, {required String? parentId, String? name}) async {
    await _c.post('/api/v1/files/$id/move', body: {
      'parent_id': parentId, // explicit null = move to root
      if (name != null) 'name': name,
    });
  }

  Future<DriveFile> copy(String id, {String? parentId, String? name}) async {
    final data = await _c.post('/api/v1/files/$id/copy', body: {
      if (parentId != null) 'parent_id': parentId,
      if (name != null) 'name': name,
    });
    return DriveFile.fromJson(data as Map<String, dynamic>);
  }

  /// Soft-delete → trash.
  Future<void> trash(String id) async => _c.delete('/api/v1/files/$id');

  // ── trash ────────────────────────────────────────────────────────────────

  Future<List<DriveFile>> listTrash() async => _items(await _c.get('/api/v1/trash'));
  Future<void> restoreTrash(String id) async => _c.post('/api/v1/trash/$id/restore');
  Future<void> purgeTrash(String id) async => _c.delete('/api/v1/trash/$id');
  Future<void> emptyTrash() async => _c.post('/api/v1/trash/empty');

  // ── star / recent ──────────────────────────────────────────────────────────

  Future<void> star(String id) async => _c.post('/api/v1/files/$id/star');
  Future<void> unstar(String id) async => _c.delete('/api/v1/files/$id/star');
  Future<List<DriveFile>> listStarred({int limit = 200}) async =>
      _items(await _c.get('/api/v1/starred', query: {'limit': limit}));
  Future<List<DriveFile>> listRecent({int limit = 50}) async =>
      _items(await _c.get('/api/v1/recent', query: {'limit': limit}));

  // ── search / users ──────────────────────────────────────────────────────────

  Future<List<DriveSearchHit>> search(String q, {int limit = 30}) async {
    final data = await _c.get('/api/v1/search', query: {'q': q, 'limit': limit});
    final hits = (data as Map?)?['hits'] as List? ?? const [];
    return hits.map((e) => DriveSearchHit.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<DriveUser>> searchUsers(String q, {int limit = 10}) async {
    final data = await _c.get('/api/v1/users/search', query: {'q': q, 'limit': limit});
    final items = (data as Map?)?['items'] as List? ?? const [];
    return items.map((e) => DriveUser.fromJson(e as Map<String, dynamic>)).toList();
  }

  // ── sharing (public links) ───────────────────────────────────────────────

  Future<List<DriveShare>> listShares() async {
    final data = await _c.get('/api/v1/shares');
    final items = (data as Map?)?['items'] as List? ?? const [];
    return items.map((e) => DriveShare.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<DriveShare> createShare(
    String resourceId, {
    String? password,
    DateTime? expiresAt,
    bool? allowDownload,
    String permission = 'viewer',
  }) async {
    final data = await _c.post('/api/v1/shares', body: {
      'resource_id': resourceId,
      if (password != null && password.isNotEmpty) 'password': password,
      if (expiresAt != null) 'expires_at': expiresAt.toUtc().toIso8601String(),
      if (allowDownload != null) 'allow_download': allowDownload,
      'permission': permission,
    });
    return DriveShare.fromJson(data as Map<String, dynamic>);
  }

  Future<void> deleteShare(String id) async => _c.delete('/api/v1/shares/$id');

  /// Update a public link (PATCH /api/v1/shares/{id}).
  Future<void> updateShare(String id, {String? permission, bool? allowDownload, DateTime? expiresAt, bool clearExpiry = false}) async {
    await _c.patch('/api/v1/shares/$id', body: {
      if (permission != null) 'permission': permission,
      if (allowDownload != null) 'allow_download': allowDownload,
      if (expiresAt != null) 'expires_at': expiresAt.toUtc().toIso8601String(),
      if (clearExpiry) 'clear_expiry': true,
    });
  }

  /// Shared-by-me listing (GET /api/v1/discovery/shared-by-me).
  Future<List<DriveFile>> listSharedByMe() async =>
      _items(await _c.get('/api/v1/discovery/shared-by-me'));

  /// Shared-with-me listing (GET /api/v1/files/shared).
  Future<List<DriveFile>> listSharedWithMe() async => _items(await _c.get('/api/v1/files/shared'));

  // ── permissions (share with user/group) ─────────────────────────────────

  Future<List<DrivePermission>> listPermissions(String resourceId) async {
    final data = await _c.get('/api/v1/permissions', query: {'resource_id': resourceId});
    final items = (data as Map?)?['items'] as List? ?? const [];
    return items.map((e) => DrivePermission.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<DrivePermission> grantPermission({
    required String resourceId,
    required String subjectType, // user | group | email (subjectId = the address)
    required String subjectId,
    required DriveRole role,
    DateTime? expiresAt,
    bool? blockReshare,
    String? emailSubject,
    String? emailMessage,
  }) async {
    final data = await _c.post('/api/v1/permissions', body: {
      'resource_id': resourceId,
      // 'email' shares with anyone by address: a WorldPosta user in another
      // organization, or a pending invite that activates on their first sign-in.
      'subject': subjectType == 'email'
          ? {'type': 'email', 'email': subjectId}
          : {'type': subjectType, 'id': subjectId},
      'role': role.wire,
      if (expiresAt != null) 'expires_at': expiresAt.toUtc().toIso8601String(),
      if (blockReshare != null) 'block_reshare': blockReshare,
      if (emailSubject != null) 'email_subject': emailSubject,
      if (emailMessage != null) 'email_message': emailMessage,
    });
    return DrivePermission.fromJson(data as Map<String, dynamic>);
  }

  Future<void> revokePermission(String permissionId) async =>
      _c.delete('/api/v1/permissions/$permissionId');

  // ── activity / changes ───────────────────────────────────────────────────

  Future<List<DriveActivity>> myActivity() async {
    final data = await _c.get('/api/v1/me/activity');
    final items = (data as Map?)?['items'] as List? ?? const [];
    return items.map((e) => DriveActivity.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// Sync delta feed. [since] is the last seen seq (0 for a full replay).
  Future<DriveChangePage> changes({int since = 0, int limit = 100}) async {
    // /changes returns {"data":{"items":[…]},"meta":{"next_cursor":"…"}}. Our
    // client unwraps `data`, so next_cursor (in meta) is derived from the last
    // item here instead — callers persist the highest seq they applied.
    final data = await _c.get('/api/v1/changes', query: {'since': since, 'limit': limit});
    final items = (((data as Map?)?['items'] as List?) ?? const [])
        .map((e) => DriveChange.fromJson(e as Map<String, dynamic>))
        .toList();
    final next = items.isEmpty ? '' : items.last.seq.toString();
    return DriveChangePage(items, items.length < limit ? '' : next);
  }

  // ── content transfer ───────────────────────────────────────────────────────

  /// Download a file's current content into memory (Range-capable).
  Future<Uint8List> download(String id, {int? rangeStart, int? rangeEnd}) =>
      _c.getBytes('/api/v1/files/$id/content', rangeStart: rangeStart, rangeEnd: rangeEnd);

  /// Simple multipart upload of a new file (small files). Returns the new file.
  Future<DriveFile> uploadFile({
    required List<int> bytes,
    required String name,
    String? parentId,
    String? contentType,
  }) async {
    // parent_id also goes in the query so the server can route an upload into a
    // folder shared from another organization before parsing the body.
    final data = await _c.postMultipart('/api/v1/files',
        query: {if (parentId != null) 'parent_id': parentId},
        bytes: bytes,
        filename: name,
        contentType: contentType,
        fields: {'name': name, if (parentId != null) 'parent_id': parentId});
    return DriveFile.fromJson(data as Map<String, dynamic>);
  }

  /// Replace an existing file's content, creating a new version (raw PUT,
  /// bypasses the 1 MiB body cap).
  /// Replace a file's content with a new version. With [ifUnchangedSince] (the
  /// file's updated_at as last seen) the server refuses with 412
  /// `changed_since` when someone saved a newer version in the meantime,
  /// instead of overwriting it.
  Future<void> replaceContent(String id, List<int> bytes, {String? contentType, DateTime? ifUnchangedSince}) async {
    await _c.putBytes('/api/v1/files/$id/content', bytes,
        contentType: contentType,
        headers: ifUnchangedSince == null
            ? null
            : {'X-Drive-Base-Updated-At': ifUnchangedSince.toUtc().toIso8601String()});
  }

  // ── versions ────────────────────────────────────────────────────────────

  Future<List<DriveVersion>> listVersions(String id) async {
    final data = await _c.get('/api/v1/files/$id/versions');
    final items = (data as Map?)?['items'] as List? ?? const [];
    return items.map((e) => DriveVersion.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> restoreVersion(String fileId, String versionId) async =>
      _c.post('/api/v1/files/$fileId/versions/$versionId/restore');

  /// Download a specific version's content.
  Future<Uint8List> downloadVersion(String fileId, String versionId) =>
      _c.getBytes('/api/v1/files/$fileId/versions/$versionId/content');

  // ── office (Collabora / WOPI) ─────────────────────────────────────────────

  /// Mint a Collabora editor URL for an Office file (POST /files/{id}/wopi-edit-url).
  /// The returned URL is fully self-contained (WOPISrc + access_token embedded,
  /// 1h TTL) — load it directly in a webview, exactly like the Drive's iframe.
  Future<({String url, bool canWrite})> wopiEditUrl(String id) async {
    final data = await _c.post('/api/v1/files/$id/wopi-edit-url', body: const {});
    final m = data as Map<String, dynamic>;
    return (url: m['url'] as String, canWrite: m['can_write'] == true);
  }

  // ── comments ────────────────────────────────────────────────────────────

  Future<List<DriveComment>> listComments(String id) async {
    final data = await _c.get('/api/v1/files/$id/comments');
    final items = (data as Map?)?['items'] as List? ?? const [];
    return items.map((e) => DriveComment.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> addComment(String id, String body) async =>
      _c.post('/api/v1/files/$id/comments', body: {'body': body});

  Future<void> deleteComment(String fileId, String commentId) async =>
      _c.delete('/api/v1/files/$fileId/comments/$commentId');

  // ── per-file activity + expiration ────────────────────────────────────────

  /// Activity for one file (GET /api/v1/files/{id}/activity).
  Future<List<DriveActivity>> fileActivity(String id) async {
    final data = await _c.get('/api/v1/files/$id/activity');
    final items = (data as Map?)?['items'] as List? ?? const [];
    return items.map((e) => DriveActivity.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// Set or clear a file's expiration (PATCH /api/v1/files/{id}/expiration).
  /// Pass null to remove the expiry.
  Future<void> setExpiration(String id, DateTime? expiresAt) async {
    await _c.patch('/api/v1/files/$id/expiration', body: {
      'expires_at': expiresAt?.toUtc().toIso8601String(),
    });
  }

  /// Upload a local file of any size via tus (resumable, 5 MiB chunks). Finalises
  /// asynchronously — the caller re-lists [parentId] afterwards to find the file.
  Future<void> uploadViaTus({
    required String localPath,
    required String filename,
    String? contentType,
    String? parentId,
    void Function(int sent, int total)? onProgress,
    bool Function()? isCancelled,
  }) =>
      _c.tusUpload(
        localPath: localPath,
        filename: filename,
        contentType: contentType ?? 'application/octet-stream',
        parentId: parentId,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );


  // ── shortcuts / pinned ───────────────────────────────────────────────────

  /// Shortcuts list (GET /api/v1/discovery/shortcuts); rows carry shortcutId.
  Future<List<DriveFile>> listShortcuts() async => _items(await _c.get('/api/v1/discovery/shortcuts'));

  /// Add a shortcut to [id] in My Drive (POST /files/{id}/shortcut).
  Future<void> addShortcut(String id) async => _c.post('/api/v1/files/$id/shortcut', body: const {});

  /// Remove a shortcut (never the target file).
  Future<void> removeShortcut(String shortcutId) async => _c.delete('/api/v1/shortcuts/$shortcutId');

  Future<List<DriveFile>> listPinned() async => _items(await _c.get('/api/v1/pinned'));
  Future<void> pin(String id) async => _c.post('/api/v1/files/$id/pin');
  Future<void> unpin(String id) async => _c.delete('/api/v1/files/$id/pin');

  // ── tags ─────────────────────────────────────────────────────────────────

  List<DriveTag> _tags(dynamic data) => (((data as Map?)?['items'] as List?) ?? const [])
      .map((e) => DriveTag.fromJson(e as Map<String, dynamic>))
      .toList();

  Future<List<DriveTag>> listTags() async => _tags(await _c.get('/api/v1/tags'));

  Future<DriveTag> createTag(String name) async =>
      DriveTag.fromJson((await _c.post('/api/v1/tags', body: {'name': name})) as Map<String, dynamic>);

  Future<List<DriveTag>> fileTags(String fileId) async => _tags(await _c.get('/api/v1/files/$fileId/tags'));

  Future<void> attachTag(String fileId, String tagId) async =>
      _c.post('/api/v1/files/$fileId/tags', body: {'tag_id': tagId});

  Future<void> detachTag(String fileId, String tagId) async => _c.delete('/api/v1/files/$fileId/tags/$tagId');

  /// Files carrying a tag, across all folders (GET /files?tag=).
  Future<List<DriveFile>> listByTag(String tagId, {int limit = 200}) async =>
      _items(await _c.get('/api/v1/files', query: {'tag': tagId, 'limit': limit}));

  // ── notifications ──────────────────────────────────────────────────────────

  Future<({List<DriveNotification> items, int unread})> notifications({int limit = 50}) async {
    final data = await _c.get('/api/v1/notifications', query: {'limit': limit}) as Map?;
    final items = ((data?['items'] as List?) ?? const [])
        .map((e) => DriveNotification.fromJson(e as Map<String, dynamic>))
        .toList();
    return (items: items, unread: (data?['unread'] as num?)?.toInt() ?? items.where((n) => !n.read).length);
  }

  Future<void> markNotificationRead(String id) async => _c.post('/api/v1/notifications/$id/read');
  Future<void> markAllNotificationsRead() async => _c.post('/api/v1/notifications/read-all');

  // ── send / export / print ─────────────────────────────────────────────────

  /// Email a file (queued; attached when [attach]). Recipient needs no account.
  Future<void> emailFile(String id, {required String to, String subject = '', String body = '', bool attach = true}) async =>
      _c.post('/api/v1/files/$id/email', body: {'to': to, 'subject': subject, 'body': body, 'attach': attach});

  /// Convert a file with Collabora (POST /files/{id}/convert?to=pdf|docx|…).
  Future<Uint8List> convert(String id, String to) => _c.postForBytes('/api/v1/files/$id/convert', query: {'to': to});

  /// Print-ready PDF of an Office file (GET /files/{id}/preview/pdf).
  Future<Uint8List> previewPdf(String id) => _c.getBytes('/api/v1/files/$id/preview/pdf');

  // ── Google Drive ────────────────────────────────────────────────────────────

  Future<GoogleConnection> googleConnection() async => GoogleConnection.fromJson(
      ((await _c.get('/api/v1/imports/google/connection')) as Map?)?.cast<String, dynamic>() ?? const {});

  /// What the user gave Posta Drive access to in Google Drive. [folder] null =
  /// the top level; a Google folder id = its children.
  Future<GooglePage> googleBrowse({String? folder, String? pageToken}) async {
    final data = await _c.get('/api/v1/imports/google/browse', query: {
      'folder': folder,
      'page_token': pageToken,
    }) as Map?;
    final items = ((data?['items'] as List?) ?? const [])
        .map((e) => GoogleItem.fromJson(e as Map<String, dynamic>))
        .toList();
    return GooglePage(items, (data?['next_page_token'] as String?) ?? '');
  }

  /// A one-time page for the app's browser sheet that connects Google Drive
  /// (if needed) and opens Google's picker, then returns to [callback]
  /// (postadrive://… or a loopback URL). Returns the path on this server.
  Future<String> googleAppLink(String callback) async {
    final data = await _c.post('/api/v1/imports/google/app-link', body: {'callback': callback}) as Map?;
    final path = data?['path'] as String?;
    if (path == null || !path.startsWith('/')) throw DriveException('bad_response', 'The server sent no Google link.', 0);
    return path;
  }

  /// Forget the Google connection (and revoke Posta Drive's access at Google).
  Future<void> googleDisconnect() async => _c.delete('/api/v1/imports/google/connection');

  /// Copy Google items into Posta Drive ([targetFolderId] null = My Drive).
  /// Runs in the background; returns the import job id.
  Future<String> googleImport(List<String> ids, {String? targetFolderId, bool importSharing = true}) async {
    final data = await _c.post('/api/v1/imports/google/start', body: {
      'mode': 'selected',
      'items': ids,
      'target_folder_id': targetFolderId,
      'import_sharing': importSharing,
    }) as Map?;
    return (data?['job_id'] as String?) ?? '';
  }
}
