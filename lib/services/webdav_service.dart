import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../config/constants.dart';
import '../models/nc_file.dart';
import 'auth_service.dart';

class WebDavService {
  final AuthService _auth;
  static http.Client? _sharedClient;

  /// Reuse a single HTTP client for connection pooling (one TLS handshake)
  http.Client get _client {
    _sharedClient ??= http.Client();
    return _sharedClient!;
  }

  /// Expose the pooled client for use by other code (sharing, reminders, etc.)
  static http.Client get sharedHttpClient {
    _sharedClient ??= http.Client();
    return _sharedClient!;
  }

  WebDavService(this._auth);

  String get _basePath =>
      '${AppConstants.webDavPath}${_auth.userId}';

  Map<String, String> get _headers => {
        'Authorization': _auth.basicAuth,
        'OCS-APIRequest': 'true',
      };

  /// Build a safe URI — encode each path segment individually
  Uri _buildUri(String remotePath) {
    final serverUri = Uri.parse(_auth.serverUrl!);
    // Split the full path into segments, encode each one
    final fullPath = '$_basePath$remotePath';
    final segments = fullPath.split('/').where((s) => s.isNotEmpty).toList();
    return serverUri.replace(pathSegments: segments);
  }

  /// Safely decode a percent-encoded string, handling malformed input
  String _safeDecode(String encoded) {
    try {
      return Uri.decodeFull(encoded);
    } catch (_) {
      // If decoding fails, return as-is
      return encoded;
    }
  }

  /// Check a folder's ETag without fetching contents (Depth:0, tiny request)
  Future<String?> getFolderEtag(String remotePath) async {
    final url = _buildUri(remotePath);
    final request = http.Request('PROPFIND', url);
    request.headers.addAll(_headers);
    request.headers['Depth'] = '0';
    request.headers['Content-Type'] = 'application/xml; charset=utf-8';
    request.body = '''<?xml version="1.0" encoding="UTF-8"?>
<d:propfind xmlns:d="DAV:">
  <d:prop><d:getetag/></d:prop>
</d:propfind>''';

    final streamedResponse = await _client.send(request);
    final response = await http.Response.fromStream(streamedResponse);
    if (response.statusCode != 207) return null;

    try {
      final doc = XmlDocument.parse(response.body);
      return doc.findAllElements('d:getetag').firstOrNull?.innerText?.replaceAll('"', '');
    } catch (_) {
      return null;
    }
  }

  /// List files in a directory using PROPFIND
  Future<List<NcFile>> listFiles(String remotePath) async {
    final url = _buildUri(remotePath);
    debugPrint('PROPFIND: $url');

    final request = http.Request('PROPFIND', url);
    request.headers.addAll(_headers);
    request.headers['Depth'] = '1';
    request.headers['Content-Type'] = 'application/xml; charset=utf-8';
    request.body = '''<?xml version="1.0" encoding="UTF-8"?>
<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
  <d:prop>
    <d:getlastmodified/>
    <d:getetag/>
    <d:getcontenttype/>
    <d:getcontentlength/>
    <d:resourcetype/>
    <oc:id/>
    <oc:fileid/>
    <oc:permissions/>
    <oc:size/>
    <oc:favorite/>
    <oc:owner-display-name/>
  </d:prop>
</d:propfind>''';

    final streamedResponse = await _client.send(request);
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode != 207) {
      throw Exception('PROPFIND failed: ${response.statusCode}');
    }

    return _parsePropfindResponse(response.body, remotePath);
  }

  List<NcFile> _parsePropfindResponse(String xmlBody, String requestPath) {
    final document = XmlDocument.parse(xmlBody);
    final responses = document.findAllElements('d:response');
    final files = <NcFile>[];

    final davPrefix = _basePath;

    for (final response in responses) {
      final href = response.findElements('d:href').firstOrNull?.innerText ?? '';
      if (href.isEmpty) continue;

      // Safely decode the href
      final decodedHref = _safeDecode(href);

      // Extract the remote path from the href
      String filePath = decodedHref;
      final davIndex = decodedHref.indexOf(davPrefix);
      if (davIndex >= 0) {
        filePath = decodedHref.substring(davIndex + davPrefix.length);
      }

      // Normalize: ensure starts with /, remove trailing /
      if (!filePath.startsWith('/')) filePath = '/$filePath';
      final cleanFilePath = filePath.endsWith('/') && filePath.length > 1
          ? filePath.substring(0, filePath.length - 1)
          : filePath;
      final cleanRequestPath = requestPath.endsWith('/') && requestPath.length > 1
          ? requestPath.substring(0, requestPath.length - 1)
          : requestPath;

      // Skip the directory itself
      if (cleanFilePath == cleanRequestPath || cleanFilePath == '/') continue;

      final propstat = response.findElements('d:propstat').firstOrNull;
      final prop = propstat?.findElements('d:prop').firstOrNull;
      if (prop == null) continue;

      final resourceType = prop.findElements('d:resourcetype').firstOrNull;
      final isDirectory =
          resourceType?.findElements('d:collection').isNotEmpty ?? false;

      // Get name from the last segment of the path
      final pathSegments = cleanFilePath.split('/').where((s) => s.isNotEmpty).toList();
      final name = pathSegments.isNotEmpty ? pathSegments.last : cleanFilePath;

      final sizeStr = prop.findElements('oc:size').firstOrNull?.innerText ??
          prop.findElements('d:getcontentlength').firstOrNull?.innerText ??
          '0';

      final lastModStr =
          prop.findElements('d:getlastmodified').firstOrNull?.innerText;

      DateTime? lastModified;
      if (lastModStr != null) {
        try {
          lastModified = HttpDate.parse(lastModStr);
        } catch (_) {}
      }

      files.add(NcFile(
        path: cleanFilePath,
        name: name,
        isDirectory: isDirectory,
        size: int.tryParse(sizeStr) ?? 0,
        lastModified: lastModified,
        etag: prop.findElements('d:getetag').firstOrNull?.innerText,
        fileId: prop.findElements('oc:fileid').firstOrNull?.innerText,
        contentType:
            prop.findElements('d:getcontenttype').firstOrNull?.innerText,
        permissions:
            prop.findElements('oc:permissions').firstOrNull?.innerText,
        isFavorite:
            prop.findElements('oc:favorite').firstOrNull?.innerText == '1',
        ownerDisplayName:
            prop.findElements('oc:owner-display-name').firstOrNull?.innerText,
      ));
    }

    // Sort: directories first, then by name
    files.sort((a, b) {
      if (a.isDirectory && !b.isDirectory) return -1;
      if (!a.isDirectory && b.isDirectory) return 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    return files;
  }

  /// Download a file (small files, loads into memory)
  Future<Uint8List> downloadFile(String remotePath) async {
    final url = _buildUri(remotePath);
    final response = await _client.get(url, headers: _headers);

    if (response.statusCode != 200) {
      throw Exception('Download failed: ${response.statusCode}');
    }

    return response.bodyBytes;
  }

  /// Stream-download a file directly to disk (works for any size)
  Future<void> downloadFileStreamed(String remotePath, String localPath) async {
    final url = _buildUri(remotePath);
    final request = http.Request('GET', url);
    request.headers.addAll(_headers);

    final streamedResponse = await _client.send(request);
    if (streamedResponse.statusCode != 200) {
      throw Exception('Download failed: ${streamedResponse.statusCode}');
    }

    final file = File(localPath);
    final sink = file.openWrite();
    try {
      await streamedResponse.stream.pipe(sink);
    } finally {
      await sink.close();
    }
  }

  /// Download file to local storage and return the file path
  Future<String> downloadFileToLocal(String remotePath, String fileName) async {
    final dir = await getApplicationDocumentsDirectory();
    final localPath = '${dir.path}/$fileName';
    await downloadFileStreamed(remotePath, localPath);
    return localPath;
  }

  /// Upload a file from bytes
  Future<void> uploadFile(String remotePath, Uint8List data, {bool failIfExists = false}) async {
    final url = _buildUri(remotePath);
    debugPrint('Upload to: $url (${data.length} bytes) failIfExists=$failIfExists');
    final response = await _client.put(
      url,
      headers: {
        ..._headers,
        'Content-Type': 'application/octet-stream',
        if (failIfExists) 'If-None-Match': '*',
      },
      body: data,
    );

    if (failIfExists && response.statusCode == 412) {
      throw Exception('FILE_EXISTS');
    }
    if (response.statusCode != 201 &&
        response.statusCode != 204 &&
        response.statusCode != 200) {
      throw Exception('Upload failed: ${response.statusCode} ${response.body}');
    }
  }

  /// Stream-upload a local file (works for any size)
  Future<void> uploadFileStreamed(String localPath, String remotePath) async {
    final url = _buildUri(remotePath);
    final file = File(localPath);
    final length = await file.length();

    final request = http.StreamedRequest('PUT', url);
    request.headers.addAll(_headers);
    request.headers['Content-Type'] = 'application/octet-stream';
    request.contentLength = length;

    file.openRead().listen(
      request.sink.add,
      onDone: () => request.sink.close(),
      onError: (e) => request.sink.addError(e),
    );

    final response = await _client.send(request);
    if (response.statusCode != 201 &&
        response.statusCode != 204 &&
        response.statusCode != 200) {
      throw Exception('Upload failed: ${response.statusCode}');
    }
  }

  /// Upload a local file by path
  Future<void> uploadLocalFile(String localPath, String remotePath) async {
    final file = File(localPath);
    final bytes = await file.readAsBytes();
    await uploadFile(remotePath, bytes);
  }

  /// Create a directory
  Future<void> createDirectory(String remotePath) async {
    final url = _buildUri(remotePath);
    final request = http.Request('MKCOL', url);
    request.headers.addAll(_headers);

    final streamedResponse = await _client.send(request);
    if (streamedResponse.statusCode != 201 &&
        streamedResponse.statusCode != 405) {
      // 405 = already exists, which is fine
      throw Exception('Create directory failed: ${streamedResponse.statusCode}');
    }
  }

  /// Delete a file or directory
  Future<void> delete(String remotePath) async {
    final url = _buildUri(remotePath);
    final response = await _client.delete(url, headers: _headers);

    if (response.statusCode != 204 && response.statusCode != 200) {
      throw Exception('Delete failed: ${response.statusCode}');
    }
  }

  /// Move/rename a file
  Future<void> move(String fromPath, String toPath) async {
    final url = _buildUri(fromPath);
    final destUrl = _buildUri(toPath);
    final request = http.Request('MOVE', url);
    request.headers.addAll(_headers);
    request.headers['Destination'] = destUrl.toString();
    request.headers['Overwrite'] = 'F';

    final streamedResponse = await _client.send(request);
    if (streamedResponse.statusCode != 201 &&
        streamedResponse.statusCode != 204) {
      throw Exception('Move failed: ${streamedResponse.statusCode}');
    }
  }

  /// Toggle favorite
  Future<void> toggleFavorite(String remotePath, bool favorite) async {
    final url = _buildUri(remotePath);
    final request = http.Request('PROPPATCH', url);
    request.headers.addAll(_headers);
    request.headers['Content-Type'] = 'application/xml';
    request.body = '''<?xml version="1.0" encoding="UTF-8"?>
<d:propertyupdate xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:set>
    <d:prop>
      <oc:favorite>${favorite ? 1 : 0}</oc:favorite>
    </d:prop>
  </d:set>
</d:propertyupdate>''';

    final streamedResponse = await _client.send(request);
    if (streamedResponse.statusCode != 207) {
      throw Exception('Toggle favorite failed: ${streamedResponse.statusCode}');
    }
  }

  /// Get storage quota info
  Future<Map<String, dynamic>> getQuota() async {
    final url = _buildUri('/');
    final request = http.Request('PROPFIND', url);
    request.headers.addAll(_headers);
    request.headers['Depth'] = '0';
    request.headers['Content-Type'] = 'application/xml';
    request.body = '''<?xml version="1.0" encoding="UTF-8"?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:quota-used-bytes/>
    <d:quota-available-bytes/>
  </d:prop>
</d:propfind>''';

    final streamedResponse = await _client.send(request);
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode != 207) {
      throw Exception('Get quota failed: ${response.statusCode}');
    }

    final document = XmlDocument.parse(response.body);
    final prop = document.findAllElements('d:prop').firstOrNull;

    final used = int.tryParse(
          prop?.findElements('d:quota-used-bytes').firstOrNull?.innerText ?? '0',
        ) ??
        0;
    final available = int.tryParse(
          prop?.findElements('d:quota-available-bytes').firstOrNull?.innerText ??
              '-1',
        ) ??
        -1;

    return {
      'used': used,
      'available': available,
      'total': available > 0 ? used + available : -1,
    };
  }

  /// Build URI for a custom DAV path (not user files)
  Uri _buildCustomDavUri(String davPath) {
    final serverUri = Uri.parse(_auth.serverUrl!);
    final segments = davPath.split('/').where((s) => s.isNotEmpty).toList();
    return serverUri.replace(pathSegments: segments);
  }

  static const _propBody = '''
    <d:getlastmodified/>
    <d:getetag/>
    <d:getcontenttype/>
    <d:getcontentlength/>
    <d:resourcetype/>
    <oc:id/>
    <oc:fileid/>
    <oc:permissions/>
    <oc:size/>
    <oc:favorite/>
    <oc:owner-display-name/>''';

  /// List favorites using REPORT
  Future<List<NcFile>> listFavorites() async {
    final url = _buildUri('/');
    final request = http.Request('REPORT', url);
    request.headers.addAll(_headers);
    request.headers['Content-Type'] = 'application/xml; charset=utf-8';
    request.headers['Depth'] = 'infinity';
    request.body = '''<?xml version="1.0" encoding="UTF-8"?>
<oc:filter-files xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
  <d:prop>$_propBody</d:prop>
  <oc:filter-rules>
    <oc:favorite>1</oc:favorite>
  </oc:filter-rules>
</oc:filter-files>''';

    final streamedResponse = await _client.send(request);
    final response = await http.Response.fromStream(streamedResponse);
    if (response.statusCode != 207) {
      throw Exception('List favorites failed: ${response.statusCode}');
    }
    return _parsePropfindResponse(response.body, '/');
  }

  /// List recent files using REPORT (last 2 weeks)
  Future<List<NcFile>> listRecent() async {
    // Use the OCS activity API or the Nextcloud recent files REPORT
    // The correct REPORT uses nc:lastmodified-before/after filter rules
    final url = _buildUri('/');

    final request = http.Request('REPORT', url);
    request.headers.addAll(_headers);
    request.headers['Content-Type'] = 'application/xml; charset=utf-8';
    // Use filter-files with empty rules to get all files, then sort client-side
    request.body = '''<?xml version="1.0" encoding="UTF-8"?>
<oc:filter-files xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
  <d:prop>$_propBody</d:prop>
  <oc:filter-rules/>
</oc:filter-files>''';

    final streamedResponse = await _client.send(request);
    final response = await http.Response.fromStream(streamedResponse);

    List<NcFile> files;
    if (response.statusCode == 207) {
      files = _parsePropfindResponse(response.body, '/');
    } else {
      debugPrint('REPORT for recent failed (${response.statusCode}), falling back to recursive listing');
      // Fallback: recursively gather files from root + first-level subdirs
      files = await _gatherRecentFiles('/');
    }

    // Filter to files only, sort by last modified descending
    files = files.where((f) => !f.isDirectory).toList();
    files.sort((a, b) => (b.lastModified ?? DateTime(2000)).compareTo(a.lastModified ?? DateTime(2000)));
    return files.take(50).toList();
  }

  /// Gather files from root and one level of subdirectories for the recent fallback
  Future<List<NcFile>> _gatherRecentFiles(String path) async {
    final items = await listFiles(path);
    final result = <NcFile>[];
    for (final item in items) {
      if (item.isDirectory) {
        // Go one level deep
        try {
          final subItems = await listFiles(item.path);
          result.addAll(subItems.where((f) => !f.isDirectory));
        } catch (_) {}
      } else {
        result.add(item);
      }
    }
    return result;
  }

  /// List trash (deleted files)
  Future<List<NcFile>> listTrash() async {
    final trashPath = '/remote.php/dav/trashbin/${_auth.userId}/trash/';
    final url = _buildCustomDavUri(trashPath);

    final request = http.Request('PROPFIND', url);
    request.headers.addAll(_headers);
    request.headers['Depth'] = '1';
    request.headers['Content-Type'] = 'application/xml; charset=utf-8';
    request.body = '''<?xml version="1.0" encoding="UTF-8"?>
<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
  <d:prop>
    <d:getlastmodified/>
    <d:getcontentlength/>
    <d:resourcetype/>
    <oc:trashbin-original-location/>
    <oc:trashbin-delete-timestamp/>
    <oc:trashbin-filename/>
    <oc:size/>
  </d:prop>
</d:propfind>''';

    final streamedResponse = await _client.send(request);
    final response = await http.Response.fromStream(streamedResponse);
    if (response.statusCode != 207) {
      throw Exception('List trash failed: ${response.statusCode}');
    }
    return _parseTrashResponse(response.body);
  }

  List<NcFile> _parseTrashResponse(String xmlBody) {
    final document = XmlDocument.parse(xmlBody);
    final responses = document.findAllElements('d:response');
    final files = <NcFile>[];
    bool first = true;

    final trashPrefix = '/remote.php/dav/trashbin/${_auth.userId}/trash/';

    for (final response in responses) {
      // Skip the first entry (the trash folder itself)
      if (first) { first = false; continue; }

      final href = response.findElements('d:href').firstOrNull?.innerText ?? '';
      if (href.isEmpty) continue;
      final decodedHref = _safeDecode(href);

      final prop = response.findElements('d:propstat').firstOrNull
          ?.findElements('d:prop').firstOrNull;
      if (prop == null) continue;

      // Try to get the filename from properties first, then fall back to href
      String? originalLocation;
      String? trashFilename;

      // Search all propstat elements for the properties (they may be in different propstats)
      for (final ps in response.findElements('d:propstat')) {
        final p = ps.findElements('d:prop').firstOrNull;
        if (p == null) continue;
        // Try multiple namespace patterns for trashbin properties
        trashFilename ??= p.findElements('oc:trashbin-filename').firstOrNull?.innerText;
        trashFilename ??= p.findElements('trashbin-filename').firstOrNull?.innerText;
        originalLocation ??= p.findElements('oc:trashbin-original-location').firstOrNull?.innerText;
        originalLocation ??= p.findElements('trashbin-original-location').firstOrNull?.innerText;
      }

      // Extract the trash item path from the href (e.g. "filename.txt.d1234567890")
      String trashItemPath = decodedHref;
      final trashIdx = decodedHref.indexOf(trashPrefix);
      if (trashIdx >= 0) {
        trashItemPath = decodedHref.substring(trashIdx + trashPrefix.length);
      }
      // Remove trailing slash
      if (trashItemPath.endsWith('/')) {
        trashItemPath = trashItemPath.substring(0, trashItemPath.length - 1);
      }

      // Derive display name: prefer trashbin-filename, then extract from href
      // Href items look like "filename.txt.d1711234567" — strip the ".dTIMESTAMP" suffix
      String name;
      if (trashFilename != null && trashFilename.isNotEmpty) {
        name = trashFilename;
      } else {
        // Extract from the trash item path, removing the .dTIMESTAMP suffix
        name = trashItemPath.split('/').last;
        final dotDIndex = name.lastIndexOf(RegExp(r'\.d\d+$'));
        if (dotDIndex > 0) {
          name = name.substring(0, dotDIndex);
        }
      }

      final resourceType = prop.findElements('d:resourcetype').firstOrNull;
      final isDirectory = resourceType?.findElements('d:collection').isNotEmpty ?? false;

      final sizeStr = prop.findElements('oc:size').firstOrNull?.innerText ??
          prop.findElements('d:getcontentlength').firstOrNull?.innerText ?? '0';

      final deleteTimestamp = prop.findElements('oc:trashbin-delete-timestamp').firstOrNull?.innerText;
      DateTime? deletedAt;
      if (deleteTimestamp != null) {
        deletedAt = DateTime.fromMillisecondsSinceEpoch((int.tryParse(deleteTimestamp) ?? 0) * 1000);
      }

      files.add(NcFile(
        // Store the trash item path (e.g. "filename.txt.d1711234567") so we can delete/restore it
        path: trashItemPath,
        name: name,
        isDirectory: isDirectory,
        size: int.tryParse(sizeStr) ?? 0,
        lastModified: deletedAt,
        ownerDisplayName: originalLocation ?? 'Me',
      ));
    }
    return files;
  }

  /// Permanently delete an item from trash
  Future<void> deleteFromTrash(String trashItemPath) async {
    final trashDavPath = '/remote.php/dav/trashbin/${_auth.userId}/trash/$trashItemPath';
    final url = _buildCustomDavUri(trashDavPath);
    final response = await _client.delete(url, headers: _headers);

    if (response.statusCode != 204 && response.statusCode != 200) {
      throw Exception('Permanent delete failed: ${response.statusCode}');
    }
  }

  /// Restore an item from trash to its original location
  Future<void> restoreFromTrash(String trashItemPath, String originalLocation, {bool isDirectory = false}) async {
    final serverUrl = _auth.serverUrl!;
    final userId = _auth.userId;

    // Nextcloud restore: MOVE from /trash/{item} to /restore/{item}
    // The server automatically puts it back in the original location
    final sourceUrl = Uri.parse('$serverUrl/remote.php/dav/trashbin/$userId/trash/$trashItemPath');
    final destUrlStr = '$serverUrl/remote.php/dav/trashbin/$userId/restore/$trashItemPath';

    debugPrint('Restore MOVE: source=$sourceUrl destination=$destUrlStr');

    final request = http.Request('MOVE', sourceUrl);
    request.headers.addAll(_headers);
    request.headers['Destination'] = destUrlStr;
    request.headers['Overwrite'] = 'T';

    final response = await _client.send(request);
    final body = await response.stream.bytesToString();
    debugPrint('Restore response: ${response.statusCode} $body');

    if (response.statusCode == 201 ||
        response.statusCode == 204 ||
        response.statusCode == 200) {
      return;
    }

    throw Exception('Restore failed (${response.statusCode}). Please try again.');
  }

  /// List shared files (using OCS sharing API)
  Future<List<NcFile>> listSharedWithMe() async {
    final url = Uri.parse(
      '${_auth.serverUrl}${AppConstants.sharesPath}?shared_with_me=true&format=json',
    );
    final response = await _client.get(url, headers: {
      ..._headers,
      'OCS-APIRequest': 'true',
    });

    if (response.statusCode != 200) {
      throw Exception('List shares failed: ${response.statusCode}');
    }

    final data = jsonDecode(response.body);
    final shares = data['ocs']?['data'] as List? ?? [];
    return shares.map<NcFile>((s) {
      final isDir = s['item_type'] == 'folder';
      return NcFile(
        path: s['file_target'] ?? s['path'] ?? '',
        name: s['file_target']?.split('/')?.last ?? s['path']?.split('/')?.last ?? 'Unknown',
        isDirectory: isDir,
        size: s['item_size'] ?? 0,
        ownerDisplayName: s['displayname_owner'] ?? s['uid_owner'] ?? '',
      );
    }).toList();
  }

  /// List shares created by the current user (shared by me)
  Future<List<NcFile>> listSharedByMe() async {
    final url = Uri.parse(
      '${_auth.serverUrl}${AppConstants.sharesPath}?format=json',
    );
    final response = await _client.get(url, headers: {
      ..._headers,
      'OCS-APIRequest': 'true',
    });

    if (response.statusCode != 200) {
      throw Exception('List shares failed: ${response.statusCode}');
    }

    final data = jsonDecode(response.body);
    final shares = data['ocs']?['data'] as List? ?? [];
    return shares.map<NcFile>((s) {
      final isDir = s['item_type'] == 'folder';
      final shareWith = s['share_with_displayname'] ?? s['share_with'] ?? '';
      final shareType = s['share_type'] ?? -1;
      String sharedTo;
      if (shareType == 3) {
        sharedTo = 'Public link';
      } else if (shareType == 4) {
        sharedTo = shareWith;
      } else {
        sharedTo = shareWith;
      }
      return NcFile(
        path: s['path'] ?? '',
        name: s['path']?.split('/')?.last ?? s['file_target']?.split('/')?.last ?? 'Unknown',
        isDirectory: isDir,
        size: s['item_size'] ?? 0,
        ownerDisplayName: sharedTo.isNotEmpty ? 'Shared with: $sharedTo' : 'Shared',
      );
    }).toList();
  }

  // ---- Chunked upload (Nextcloud chunked upload v1 protocol) ---------------

  /// Size threshold: files smaller than this use a simple PUT.
  static const int _chunkSize = 5 * 1024 * 1024; // 5 MB

  /// In-memory map of localPath -> upload UUID so an interrupted upload can be
  /// resumed within the same app session.  For cross-restart persistence the
  /// caller should store the UUID externally (e.g. SharedPreferences).
  final Map<String, String> _activeUploadUuids = {};

  /// Upload a file using the Nextcloud chunked upload protocol for files
  /// >= 5 MB, or a simple PUT for smaller files.
  ///
  /// [localPath]  — absolute path to the file on disk.
  /// [remotePath] — destination path relative to the user's files root
  ///               (e.g. `/Documents/large.zip`).
  /// [uploadUuid] — optional UUID to resume a previous upload attempt.
  Future<void> uploadFileChunked(String localPath, String remotePath,
      {String? uploadUuid}) async {
    final file = File(localPath);
    final fileSize = await file.length();

    // Small files — just use a normal PUT.
    if (fileSize < _chunkSize) {
      await uploadFileStreamed(localPath, remotePath);
      _activeUploadUuids.remove(localPath);
      return;
    }

    final uuid = uploadUuid ?? _activeUploadUuids[localPath] ?? const Uuid().v4();
    _activeUploadUuids[localPath] = uuid;

    final username = _auth.userId!;
    final uploadDirDav = '/remote.php/dav/uploads/$username/$uuid';

    // 1. MKCOL — create upload directory (ignore 405 = already exists).
    try {
      final mkcolUri = _buildCustomDavUri('$uploadDirDav/');
      final mkcolReq = http.Request('MKCOL', mkcolUri);
      mkcolReq.headers.addAll(_headers);
      final mkcolResp = await mkcolReq.send();
      if (mkcolResp.statusCode != 201 && mkcolResp.statusCode != 405) {
        throw Exception(
            'MKCOL for chunked upload failed: ${mkcolResp.statusCode}');
      }
    } catch (e) {
      if (e is Exception &&
          e.toString().contains('MKCOL for chunked upload failed')) {
        rethrow;
      }
      // MKCOL might fail if directory already exists — that's fine for resume.
      debugPrint('MKCOL warning (may already exist): $e');
    }

    // 2. Determine which chunks already exist on the server (for resume).
    final existingChunks = await _listExistingChunks(uploadDirDav);

    // 3. Upload chunks.
    final totalChunks = (fileSize / _chunkSize).ceil();
    final raf = await file.open(mode: FileMode.read);
    try {
      for (int i = 0; i < totalChunks; i++) {
        final chunkIndex = i + 1; // 1-based chunk names
        if (existingChunks.contains(chunkIndex)) {
          debugPrint('Chunk $chunkIndex/$totalChunks already uploaded, skipping');
          continue;
        }

        final offset = i * _chunkSize;
        final remaining = fileSize - offset;
        final thisChunkSize = remaining < _chunkSize ? remaining : _chunkSize;

        await raf.setPosition(offset);
        final bytes = await raf.read(thisChunkSize);

        final chunkUri =
            _buildCustomDavUri('$uploadDirDav/$chunkIndex');
        final putReq = http.Request('PUT', chunkUri);
        putReq.headers.addAll(_headers);
        putReq.headers['Content-Type'] = 'application/octet-stream';
        putReq.bodyBytes = bytes;

        final putResp = await putReq.send();
        if (putResp.statusCode != 201 && putResp.statusCode != 204) {
          throw Exception(
              'Chunk $chunkIndex upload failed: ${putResp.statusCode}');
        }
        debugPrint('Uploaded chunk $chunkIndex/$totalChunks');
      }
    } finally {
      await raf.close();
    }

    // 4. MOVE — assemble the file at the destination.
    final moveSourceUri =
        _buildCustomDavUri('$uploadDirDav/.file');
    final destUri = _buildUri(remotePath);

    final moveReq = http.Request('MOVE', moveSourceUri);
    moveReq.headers.addAll(_headers);
    moveReq.headers['Destination'] = destUri.toString();
    moveReq.headers['Overwrite'] = 'T';

    final moveResp = await moveReq.send();
    if (moveResp.statusCode != 201 &&
        moveResp.statusCode != 204 &&
        moveResp.statusCode != 200) {
      throw Exception(
          'Chunked upload MOVE failed: ${moveResp.statusCode}');
    }

    // Success — clean up tracking.
    _activeUploadUuids.remove(localPath);
    debugPrint('Chunked upload complete: $localPath -> $remotePath');
  }

  /// Get the active upload UUID for a file (for external persistence).
  String? getActiveUploadUuid(String localPath) => _activeUploadUuids[localPath];

  /// List existing chunk numbers in the upload directory (for resume).
  Future<Set<int>> _listExistingChunks(String uploadDirDav) async {
    final chunks = <int>{};
    try {
      final propfindUri = _buildCustomDavUri('$uploadDirDav/');
      final req = http.Request('PROPFIND', propfindUri);
      req.headers.addAll(_headers);
      req.headers['Depth'] = '1';
      req.headers['Content-Type'] = 'application/xml; charset=utf-8';
      req.body = '''<?xml version="1.0" encoding="UTF-8"?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:getcontentlength/>
  </d:prop>
</d:propfind>''';

      final streamedResp = await req.send();
      final resp = await http.Response.fromStream(streamedResp);
      if (resp.statusCode == 207) {
        final doc = XmlDocument.parse(resp.body);
        for (final response in doc.findAllElements('d:response')) {
          final href =
              response.findElements('d:href').firstOrNull?.innerText ?? '';
          // Extract the last path segment as the chunk number.
          final segments =
              href.split('/').where((s) => s.isNotEmpty).toList();
          if (segments.isNotEmpty) {
            final num = int.tryParse(segments.last);
            if (num != null) chunks.add(num);
          }
        }
      }
    } catch (e) {
      debugPrint('Could not list existing chunks (fresh upload): $e');
    }
    return chunks;
  }

  /// Get activity feed from the server
  Future<List<Map<String, dynamic>>> getActivity({int limit = 50}) async {
    final url = Uri.parse(
      '${_auth.serverUrl}/ocs/v2.php/apps/activity/api/v2/activity?format=json&limit=$limit',
    );
    final response = await _client.get(url, headers: {
      ..._headers,
      'OCS-APIRequest': 'true',
    });

    if (response.statusCode != 200) {
      throw Exception('Get activity failed: ${response.statusCode}');
    }

    final data = jsonDecode(response.body);
    final activities = data['ocs']?['data'] as List? ?? [];
    return activities.cast<Map<String, dynamic>>();
  }

  /// Get activity for a specific file by file ID
  Future<List<Map<String, dynamic>>> getFileActivity(String fileId, {int limit = 30}) async {
    final url = Uri.parse(
      '${_auth.serverUrl}/ocs/v2.php/apps/activity/api/v2/activity/filter?format=json&limit=$limit&object_type=files&object_id=$fileId',
    );
    final response = await _client.get(url, headers: {
      ..._headers,
      'OCS-APIRequest': 'true',
    });

    if (response.statusCode != 200) {
      return []; // Return empty if not supported
    }

    final data = jsonDecode(response.body);
    final activities = data['ocs']?['data'] as List? ?? [];
    return activities.cast<Map<String, dynamic>>();
  }

  /// Search files by name
  Future<List<NcFile>> search(String query) async {
    final url = _buildUri('/');
    final request = http.Request('REPORT', url);
    request.headers.addAll(_headers);
    request.headers['Content-Type'] = 'application/xml; charset=utf-8';
    request.body = '''<?xml version="1.0" encoding="UTF-8"?>
<oc:filter-files xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
  <d:prop>$_propBody</d:prop>
  <oc:filter-rules/>
</oc:filter-files>''';

    final streamedResponse = await _client.send(request);
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode == 207) {
      final all = _parsePropfindResponse(response.body, '/');
      final q = query.toLowerCase();
      return all.where((f) => f.name.toLowerCase().contains(q)).toList();
    }

    // Fallback: list root and filter client-side
    debugPrint('Search REPORT failed, falling back to client-side filter');
    final all = await listFiles('/');
    final q = query.toLowerCase();
    return all.where((f) => f.name.toLowerCase().contains(q)).toList();
  }

}
