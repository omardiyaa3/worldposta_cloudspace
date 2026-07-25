// DriveFile — the WorldPosta Drive file/folder model.
//
// The new Drive is UUID-addressed: every item has an `id` and a `parentId`
// (null at the drive root) and is either a file or a folder (`kind`). Unlike
// the old Nextcloud client there is NO server-side path — breadcrumbs are
// rebuilt from GET /files/{id}/path.
//
// The backend serialises files in three slightly different shapes
// (FileItemResponse, search.FileItem, QuickAccessItem, plus the trash shape).
// This single model tolerates all of them: only the six always-present fields
// are required, everything else is optional.

/// The five-level named permission ladder used by the Drive. Ordered by rank;
/// compare with [rank]. Mirrors internal/domain/permission.
enum DriveRole { viewer, commenter, editor, manager, owner }

extension DriveRoleX on DriveRole {
  int get rank => index + 1; // viewer=1 … owner=5
  String get wire => name; // JSON value is the lowercase name

  static DriveRole? fromWire(String? s) {
    if (s == null) return null;
    for (final r in DriveRole.values) {
      if (r.name == s) return r;
    }
    return null;
  }
}

class DriveFile {
  // ── always present ────────────────────────────────────────────────────────
  final String id;
  final bool isDirectory; // kind == "folder"
  final String name;
  final int sizeBytes;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  // ── optional metadata (omitempty on the wire) ─────────────────────────────
  final String? parentId;
  final String? mimeType;
  final String? classification;
  final bool legalHold;
  final String? scanStatus;
  final String? color;
  final String? emoji;
  final int? commentCount;
  final int? editorsCount;
  final DateTime? expiresAt;
  final String? permissionId;
  final DriveRole? myRole;
  final bool? canEdit;

  // ── trash-only ────────────────────────────────────────────────────────────
  final DateTime? deletedAt;
  final DateTime? purgeAfter;

  // ── quick-access-only ─────────────────────────────────────────────────────
  final DateTime? lastAccess;

  // ── client-side only (star state, tracked locally / via /starred) ──────────
  final bool isStarred;

  const DriveFile({
    required this.id,
    required this.isDirectory,
    required this.name,
    this.sizeBytes = 0,
    this.createdAt,
    this.updatedAt,
    this.parentId,
    this.mimeType,
    this.classification,
    this.legalHold = false,
    this.scanStatus,
    this.color,
    this.emoji,
    this.commentCount,
    this.editorsCount,
    this.expiresAt,
    this.permissionId,
    this.myRole,
    this.canEdit,
    this.deletedAt,
    this.purgeAfter,
    this.lastAccess,
    this.isStarred = false,
  });

  factory DriveFile.fromJson(Map<String, dynamic> j) {
    DateTime? ts(Object? v) => v is String && v.isNotEmpty ? DateTime.tryParse(v) : null;
    int asInt(Object? v) => v is int ? v : (v is num ? v.toInt() : (v is String ? int.tryParse(v) ?? 0 : 0));

    return DriveFile(
      id: j['id'] as String,
      isDirectory: (j['kind'] as String?) == 'folder',
      name: (j['name'] as String?) ?? '',
      sizeBytes: asInt(j['size_bytes']),
      createdAt: ts(j['created_at']),
      // trash rows carry deleted_at instead of updated_at
      updatedAt: ts(j['updated_at']) ?? ts(j['last_access']),
      parentId: j['parent_id'] as String?,
      mimeType: j['mime_type'] as String?,
      classification: j['classification'] as String?,
      legalHold: j['legal_hold'] == true,
      scanStatus: j['scan_status'] as String?,
      color: j['color'] as String?,
      emoji: j['emoji'] as String?,
      commentCount: j['comment_count'] is num ? (j['comment_count'] as num).toInt() : null,
      editorsCount: j['editors_count'] is num ? (j['editors_count'] as num).toInt() : null,
      expiresAt: ts(j['expires_at']),
      permissionId: j['permission_id'] as String?,
      myRole: DriveRoleX.fromWire(j['my_role'] as String?),
      canEdit: j['can_edit'] as bool?,
      deletedAt: ts(j['deleted_at']),
      purgeAfter: ts(j['purge_after']),
      lastAccess: ts(j['last_access']),
    );
  }

  /// Filename extension (lowercased, no dot), empty for folders.
  String get extension {
    if (isDirectory) return '';
    final dot = name.lastIndexOf('.');
    return dot > 0 && dot < name.length - 1 ? name.substring(dot + 1).toLowerCase() : '';
  }

  bool get isInfected => scanStatus == 'infected' || scanStatus == 'blocked';

  /// Server never grants edit on a legal-held item; default permissive when the
  /// field is absent (owner-listing endpoints omit it).
  bool get writable => (canEdit ?? true) && !legalHold;

  String get sizeFormatted {
    final b = sizeBytes;
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  DriveFile copyWith({
    String? name,
    String? parentId,
    bool? isStarred,
    bool? canEdit,
  }) =>
      DriveFile(
        id: id,
        isDirectory: isDirectory,
        name: name ?? this.name,
        sizeBytes: sizeBytes,
        createdAt: createdAt,
        updatedAt: updatedAt,
        parentId: parentId ?? this.parentId,
        mimeType: mimeType,
        classification: classification,
        legalHold: legalHold,
        scanStatus: scanStatus,
        color: color,
        emoji: emoji,
        commentCount: commentCount,
        editorsCount: editorsCount,
        expiresAt: expiresAt,
        permissionId: permissionId,
        myRole: myRole,
        canEdit: canEdit ?? this.canEdit,
        deletedAt: deletedAt,
        purgeAfter: purgeAfter,
        lastAccess: lastAccess,
        isStarred: isStarred ?? this.isStarred,
      );
}

/// One breadcrumb node from GET /files/{id}/path.
class DrivePathNode {
  final String id;
  final String name;
  final bool isDirectory;
  const DrivePathNode({required this.id, required this.name, required this.isDirectory});

  factory DrivePathNode.fromJson(Map<String, dynamic> j) => DrivePathNode(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? '',
        isDirectory: (j['kind'] as String?) == 'folder',
      );
}
