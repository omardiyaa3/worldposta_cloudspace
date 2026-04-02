class NcFile {
  final String path;
  final String name;
  final bool isDirectory;
  final int size;
  final DateTime? lastModified;
  final String? etag;
  final String? fileId;
  final String? contentType;
  final String? permissions;
  final bool isFavorite;
  final String? ownerDisplayName;

  NcFile({
    required this.path,
    required this.name,
    required this.isDirectory,
    this.size = 0,
    this.lastModified,
    this.etag,
    this.fileId,
    this.contentType,
    this.permissions,
    this.isFavorite = false,
    this.ownerDisplayName,
  });

  String get extension {
    if (isDirectory) return '';
    final parts = name.split('.');
    return parts.length > 1 ? parts.last : '';
  }

  String get sizeFormatted {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    if (size < 1024 * 1024 * 1024) {
      return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(size / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  NcFile copyWith({bool? isFavorite, String? name, String? path}) => NcFile(
    path: path ?? this.path,
    name: name ?? this.name,
    isDirectory: isDirectory,
    size: size,
    lastModified: lastModified,
    etag: etag,
    fileId: fileId,
    contentType: contentType,
    permissions: permissions,
    isFavorite: isFavorite ?? this.isFavorite,
    ownerDisplayName: ownerDisplayName,
  );

  String get parentPath {
    final parts = path.split('/');
    parts.removeLast();
    return parts.join('/');
  }
}
