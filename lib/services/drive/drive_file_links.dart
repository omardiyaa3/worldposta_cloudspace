// drive_file_links.dart — open Drive file links (https://<drive>/file/<id>) in
// the app.
//
// The Drive website publishes apple-app-site-association and assetlinks.json
// claiming /file/*, so on iPhone, iPad, Mac and Android a file link tapped in
// Link, Mail, Notes… opens Posta Drive instead of the browser. This keeps the
// link until the app can act on it (after sign-in if needed); the home shell
// then picks the account that can see the file and opens it.
//
// Windows and Linux are not wired: there, links keep opening the website.

import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

import 'drive_account.dart';
import 'drive_client.dart';

final _uuid = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

/// The file id in a Drive file link, or null when [u] isn't one.
String? fileIdFromLink(Uri u) {
  if (u.scheme != 'https' && u.scheme != 'http') return null;
  final segs = u.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segs.length != 2 || segs[0] != 'file' || !_uuid.hasMatch(segs[1])) return null;
  return segs[1].toLowerCase();
}

String _host(String url) => Uri.tryParse(url)?.host.toLowerCase() ?? '';

/// How a file link ended up.
enum FileLinkOutcome { open, noAccess, failed }

class FileLinkTarget {
  final FileLinkOutcome outcome;
  final String? accountId; // the account to open it with (open only)
  final Object? error; // failed only
  const FileLinkTarget(this.outcome, {this.accountId, this.error});
}

/// Which signed-in account can open [fileId] from a link on [linkHost]: the
/// active account first, then the others on the same Drive. [probe] loads the
/// file as that account (throws [DriveException] on 403/404). A network or
/// server error stops the search and is reported, so the user isn't told
/// "no access" when the Drive simply couldn't be reached.
Future<FileLinkTarget> findAccountForFile({
  required String linkHost,
  required List<DriveAccount> accounts,
  required String? activeId,
  required Future<void> Function(DriveAccount a) probe,
}) async {
  final host = linkHost.toLowerCase();
  final onHost = accounts.where((a) => _host(a.serverUrl) == host).toList()
    ..sort((a, b) => (a.id == activeId ? 0 : 1).compareTo(b.id == activeId ? 0 : 1));
  for (final a in onHost) {
    try {
      await probe(a);
      return FileLinkTarget(FileLinkOutcome.open, accountId: a.id);
    } on DriveException catch (e) {
      if (e.status == 403 || e.status == 404 || e.isNotFound || e.code == 'permission_denied') continue;
      return FileLinkTarget(FileLinkOutcome.failed, error: e);
    } catch (e) {
      return FileLinkTarget(FileLinkOutcome.failed, error: e);
    }
  }
  return const FileLinkTarget(FileLinkOutcome.noAccess);
}

/// Holds the latest file link the app was opened with until it is handled.
class DriveFileLinks extends ChangeNotifier {
  DriveFileLinks._();
  static final DriveFileLinks instance = DriveFileLinks._();

  Uri? _pending;
  StreamSubscription<Uri>? _sub;

  /// The link waiting to be opened (not cleared).
  Uri? get pending => _pending;

  static bool get supported => Platform.isIOS || Platform.isAndroid || Platform.isMacOS;

  /// Start listening (cold start + while running). Safe to call once at launch.
  Future<void> start() async {
    if (!supported || _sub != null) return;
    final links = AppLinks();
    _sub = links.uriLinkStream.listen(push, onError: (_) {});
    try {
      final first = await links.getInitialLink();
      if (first != null) push(first);
    } catch (_) {/* no launch link */}
  }

  /// Queue [u] if it is a Drive file link.
  void push(Uri u) {
    if (fileIdFromLink(u) == null) return;
    _pending = u;
    notifyListeners();
  }

  /// Take the pending link (clears it).
  Uri? take() {
    final u = _pending;
    _pending = null;
    return u;
  }
}
