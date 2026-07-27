// drive_client.dart — low-level HTTP wrapper for the WorldPosta Drive API.
//
// Mirrors the Drive web client (web/src/api/client.ts): every response is a
// {"data": …} envelope on success and {"error":{"code","message"}} on failure;
// this wrapper unwraps `data` and throws a typed [DriveException] otherwise.
//
// ISOLATION INVARIANT — "each one only sees his stuff":
// A DriveClient is bound to exactly one account's `dk_` token, captured at
// construction and injected as `Authorization: Bearer …` on EVERY request. The
// token is the sole credential; there is no global/default auth header and no
// cookie jar. The server resolves the token → (tenant, user) and enforces
// Postgres RLS + per-file visibility, so one account can never see another's
// data as long as each account uses its own DriveClient. We assert the token is
// present so an unauthenticated request can never be sent by accident.
//
// Pure Dart (only `http` + dart:convert/typed_data) — no Flutter imports — so it
// can be exercised by a plain `dart run` harness against a live backend.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

/// A typed API error carrying the Drive's error `code` (e.g. `not_found`,
/// `permission_denied`, `unauthenticated`, `quota_exceeded`, `validation_error`,
/// `conflict`, `legal_hold`, `account_suspended`, `rate_limited`, `internal`).
class DriveException implements Exception {
  final String code;
  final String message;
  final int status;
  DriveException(this.code, this.message, this.status);

  bool get isAuth => status == 401 || code == 'unauthenticated';
  bool get isSuspended => code == 'account_suspended';
  bool get isNotFound => status == 404 || code == 'not_found';
  bool get isQuota => status == 507 || code == 'quota_exceeded';
  bool get isConflict => status == 409 || code == 'conflict';

  @override
  String toString() => 'DriveException($status $code: $message)';
}

class DriveClient {
  final String baseUrl; // e.g. https://drive.worldposta.com (no trailing slash)
  final String token; // dk_… — this account's credential
  final http.Client _http;

  DriveClient({
    required String baseUrl,
    required this.token,
    http.Client? httpClient,
  })  : baseUrl = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl,
        _http = httpClient ?? _shared {
    assert(token.isNotEmpty, 'DriveClient requires a bound account token');
  }

  /// One pooled client for connection reuse. Safe to share across accounts:
  /// auth is per-request, never stored on the client.
  static final http.Client _shared = http.Client();

  Map<String, String> get _authHeaders => {'Authorization': 'Bearer $token'};

  Uri _uri(String path, [Map<String, dynamic>? query]) {
    final base = Uri.parse('$baseUrl$path');
    if (query == null) return base;
    final q = <String, String>{};
    query.forEach((k, v) {
      if (v == null) return;
      final s = v.toString();
      if (s.isNotEmpty) q[k] = s;
    });
    return q.isEmpty ? base : base.replace(queryParameters: q);
  }

  // ── JSON verbs ─────────────────────────────────────────────────────────────

  Future<dynamic> get(String path, {Map<String, dynamic>? query}) =>
      _send('GET', _uri(path, query));

  Future<dynamic> post(String path, {Object? body, Map<String, String>? headers}) =>
      _send('POST', _uri(path), body: body, extraHeaders: headers);

  Future<dynamic> patch(String path, {Object? body}) => _send('PATCH', _uri(path), body: body);

  Future<dynamic> put(String path, {Object? body}) => _send('PUT', _uri(path), body: body);

  Future<dynamic> delete(String path) => _send('DELETE', _uri(path));

  /// Sends a request and returns the unwrapped `data`, or `null` for an empty
  /// (204) body. Throws [DriveException] on any non-2xx.
  Future<dynamic> _send(String method, Uri uri,
      {Object? body, Map<String, String>? extraHeaders}) async {
    final req = http.Request(method, uri);
    req.headers.addAll(_authHeaders);
    if (extraHeaders != null) req.headers.addAll(extraHeaders);
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    final streamed = await _http.send(req);
    final res = await http.Response.fromStream(streamed);
    return _unwrap(res);
  }

  dynamic _unwrap(http.Response res) {
    final text = res.body;
    dynamic parsed;
    if (text.isNotEmpty) {
      try {
        parsed = jsonDecode(text);
      } catch (_) {
        parsed = null;
      }
    }
    if (res.statusCode >= 200 && res.statusCode < 300) {
      // 204 / empty body (group ops, publish, snooze, retention, …) → null.
      if (parsed is Map && parsed.containsKey('data')) return parsed['data'];
      return parsed;
    }
    // Error envelope.
    String code = 'unknown';
    String message = 'request failed (${res.statusCode})';
    if (parsed is Map && parsed['error'] is Map) {
      final e = parsed['error'] as Map;
      code = (e['code'] as String?) ?? code;
      message = (e['message'] as String?) ?? message;
    }
    throw DriveException(code, message, res.statusCode);
  }

  // ── Binary download (Range-capable) ─────────────────────────────────────────

  /// Streams a file's content to memory. Pass [rangeStart]/[rangeEnd] for a
  /// partial download (HTTP Range → 206). Throws [DriveException] on failure.
  Future<Uint8List> getBytes(String path, {int? rangeStart, int? rangeEnd}) async {
    final req = http.Request('GET', _uri(path));
    req.headers.addAll(_authHeaders);
    if (rangeStart != null) {
      final end = rangeEnd != null ? rangeEnd.toString() : '';
      req.headers['Range'] = 'bytes=$rangeStart-$end';
    }
    final streamed = await _http.send(req);
    final bytes = await streamed.stream.toBytes();
    final sc = streamed.statusCode;
    if (sc == 200 || sc == 206) return bytes;
    // Error bodies are small JSON envelopes.
    throw _errorFromBytes(bytes, sc);
  }

  /// Opens a streamed GET (for progress-tracked / large downloads).
  Future<http.StreamedResponse> openDownload(String path, {int? rangeStart}) async {
    final req = http.Request('GET', _uri(path));
    req.headers.addAll(_authHeaders);
    if (rangeStart != null && rangeStart > 0) req.headers['Range'] = 'bytes=$rangeStart-';
    final streamed = await _http.send(req);
    if (streamed.statusCode != 200 && streamed.statusCode != 206) {
      throw _errorFromBytes(await streamed.stream.toBytes(), streamed.statusCode);
    }
    return streamed;
  }

  // ── Simple multipart upload (POST /files) ───────────────────────────────────

  /// Uploads bytes as multipart/form-data to [path]. Used for small files and
  /// where tus is unnecessary. Returns the unwrapped `data`.
  Future<dynamic> postMultipart(
    String path, {
    required List<int> bytes,
    required String filename,
    String? contentType,
    Map<String, String> fields = const {},
  }) async {
    final req = http.MultipartRequest('POST', _uri(path));
    req.headers.addAll(_authHeaders);
    req.fields.addAll(fields);
    req.files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    final res = await http.Response.fromStream(await _http.send(req));
    return _unwrap(res);
  }

  /// Raw-body PUT (e.g. PUT /files/{id}/content). The path contains `/content`
  /// so the server bypasses its 1 MiB JSON body cap. Returns unwrapped `data`.
  Future<dynamic> putBytes(String path, List<int> bytes, {String? contentType}) async {
    final req = http.Request('PUT', _uri(path));
    req.headers.addAll(_authHeaders);
    req.headers['Content-Type'] = contentType ?? 'application/octet-stream';
    req.bodyBytes = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final res = await http.Response.fromStream(await _http.send(req));
    return _unwrap(res);
  }

  // ── tus resumable upload (POST /uploads/…) ─────────────────────────────────

  /// Upload a file via the tus 1.0.0 protocol (mounted at `<base>/uploads/`).
  /// Works for any size and bypasses the 1 MiB multipart cap. Streams from disk
  /// in 5 MiB chunks so memory stays bounded. Reports progress and honours
  /// cancellation. Returns nothing — tus finalises asynchronously and never
  /// returns the new file id, so the caller must re-list the parent to find it.
  Future<void> tusUpload({
    required String localPath,
    required String filename,
    required String contentType,
    String? parentId,
    void Function(int sent, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final file = File(localPath);
    final total = await file.length();

    // 1. Create the upload.
    final meta = _tusMetadata({
      'filename': filename,
      'filetype': contentType.isEmpty ? 'application/octet-stream' : contentType,
      if (parentId != null) 'parent_id': parentId,
    });
    final createReq = http.Request('POST', _uri('/uploads/'))
      ..headers.addAll(_authHeaders)
      ..headers['Tus-Resumable'] = '1.0.0'
      ..headers['Upload-Length'] = total.toString()
      ..headers['Upload-Metadata'] = meta;
    final createRes = await _http.send(createReq);
    await createRes.stream.drain<void>();
    if (createRes.statusCode != 201) {
      throw DriveException('tus_create', 'upload could not start (${createRes.statusCode})', createRes.statusCode);
    }
    final location = createRes.headers['location'];
    if (location == null || location.isEmpty) {
      throw DriveException('tus_create', 'server did not return an upload location', 502);
    }
    final uploadUri = Uri.parse(location);

    // 2. PATCH in 1 MiB chunks. Progress is reported per chunk (per real network
    // round-trip), so smaller chunks give a smoother, honest progress bar.
    const chunkSize = 1 * 1024 * 1024;
    final raf = await file.open(mode: FileMode.read);
    try {
      int offset = 0;
      while (offset < total) {
        if (isCancelled?.call() == true) {
          throw DriveException('cancelled', 'upload cancelled', 0);
        }
        final want = (offset + chunkSize > total) ? total - offset : chunkSize;
        await raf.setPosition(offset);
        final chunk = await raf.read(want);

        final patchReq = http.Request('PATCH', uploadUri)
          ..headers.addAll(_authHeaders)
          ..headers['Tus-Resumable'] = '1.0.0'
          ..headers['Upload-Offset'] = offset.toString()
          ..headers['Content-Type'] = 'application/offset+octet-stream'
          ..bodyBytes = chunk;
        final patchRes = await http.Response.fromStream(await _http.send(patchReq));
        if (patchRes.statusCode != 204) {
          throw DriveException('tus_patch', 'upload chunk failed (${patchRes.statusCode})', patchRes.statusCode);
        }
        offset = int.tryParse(patchRes.headers['upload-offset'] ?? '') ?? (offset + want);
        onProgress?.call(offset, total);
      }
    } finally {
      await raf.close();
    }
  }

  /// Encode tus Upload-Metadata: comma-separated `key base64(value)` pairs.
  String _tusMetadata(Map<String, String> pairs) => pairs.entries
      .map((e) => '${e.key} ${base64.encode(utf8.encode(e.value))}')
      .join(',');

  DriveException _errorFromBytes(Uint8List bytes, int status) {
    try {
      final parsed = jsonDecode(utf8.decode(bytes));
      if (parsed is Map && parsed['error'] is Map) {
        final e = parsed['error'] as Map;
        return DriveException(
            (e['code'] as String?) ?? 'unknown', (e['message'] as String?) ?? 'download failed', status);
      }
    } catch (_) {}
    return DriveException('unknown', 'request failed ($status)', status);
  }
}
