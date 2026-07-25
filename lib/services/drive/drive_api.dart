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
  final String subjectType; // user | group
  final String subjectId;
  final String? subjectEmail;
  final String? subjectName;
  final DriveRole role;
  final String? inheritedFrom;
  final DateTime? expiresAt;
  final bool blockReshare;
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
    required String subjectType, // user | group
    required String subjectId,
    required DriveRole role,
    DateTime? expiresAt,
    bool? blockReshare,
    String? emailSubject,
    String? emailMessage,
  }) async {
    final data = await _c.post('/api/v1/permissions', body: {
      'resource_id': resourceId,
      'subject': {'type': subjectType, 'id': subjectId},
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
    final data = await _c.postMultipart('/api/v1/files',
        bytes: bytes,
        filename: name,
        contentType: contentType,
        fields: {'name': name, if (parentId != null) 'parent_id': parentId});
    return DriveFile.fromJson(data as Map<String, dynamic>);
  }

  /// Replace an existing file's content, creating a new version (raw PUT,
  /// bypasses the 1 MiB body cap).
  Future<void> replaceContent(String id, List<int> bytes, {String? contentType}) async {
    await _c.putBytes('/api/v1/files/$id/content', bytes, contentType: contentType);
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
}
