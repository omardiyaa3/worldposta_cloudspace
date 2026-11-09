// drive_google_screen.dart — the "Google Drive" section: what the user gave
// Posta Drive access to in Google Drive (Google's drive.file permission: only
// the files and folders picked in Google's picker, which is web-only).
//
// Browse folders, open an item in Google, or copy items into Posta Drive
// (an import job on the server). Connecting and picking more happen on the web;
// the app only says where (no link): opened signed-out in a browser, the Drive
// website forwards to the SSO sign-in page, whose business sign-up link the
// App Store doesn't allow (guideline 3.1.1).

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config/theme.dart';
import '../../services/drive/drive_account_manager.dart';
import '../../services/drive/drive_api.dart';
import '../../services/drive/drive_cache.dart';
import '../../services/drive/drive_client.dart';
import 'drive_files_screen.dart' show pickDriveFolder;

const _googleFolderMime = 'application/vnd.google-apps.folder';

class DriveGoogleScreen extends StatefulWidget {
  /// Injected in tests; otherwise the active account's API / server.
  final DriveApi? api;
  final String? serverUrl;
  final Future<bool> Function(Uri)? launcher;
  const DriveGoogleScreen({super.key, this.api, this.serverUrl, this.launcher});

  @override
  State<DriveGoogleScreen> createState() => _DriveGoogleScreenState();
}

class _DriveGoogleScreenState extends State<DriveGoogleScreen> {
  GoogleConnection? _conn;
  bool _loading = true;
  String? _error;
  final List<({String id, String name})> _path = []; // empty = top level
  List<GoogleItem> _items = [];
  String _next = '';
  bool _loadingMore = false;
  final Set<String> _selected = {};

  DriveApi get _api => widget.api ?? context.read<DriveAccountManager>().activeApi!;
  String get _server => widget.serverUrl ?? context.read<DriveAccountManager>().activeAccount?.serverUrl ?? '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _launch(Uri u) async {
    final l = widget.launcher;
    if (l != null) {
      await l(u);
      return;
    }
    await launchUrl(u, mode: LaunchMode.externalApplication);
  }

  /// Where to do it on the web — text only, see the note at the top.
  Future<void> _webOnly(String title, String step) {
    final host = Uri.tryParse(_server)?.host;
    final site = (host == null || host.isEmpty) ? 'the Posta Drive website' : host;
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text('This is done on the web: sign in to Posta Drive at $site, open Google Drive and choose “$step”. '
            'Then come back here and refresh.'),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final conn = await _api.googleConnection();
      _conn = conn;
      if (conn.connected) await _browse(reset: true);
    } catch (e) {
      _error = friendlyError(e);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _browse({bool reset = false}) async {
    try {
      final page = await _api.googleBrowse(
        folder: _path.isEmpty ? null : _path.last.id,
        pageToken: reset ? null : _next,
      );
      if (!mounted) return;
      setState(() {
        _items = reset ? page.items : [..._items, ...page.items];
        _next = page.nextPageToken;
        if (reset) _selected.clear();
      });
    } on DriveException catch (e) {
      // Google access expired or was revoked → back to "connect".
      if (e.code == 'not_connected') {
        if (mounted) {
          setState(() => _conn = GoogleConnection(configured: true, connected: false, email: _conn?.email));
        }
        return;
      }
      rethrow;
    }
  }

  Future<void> _enter(GoogleItem f) async {
    _path.add((id: f.id, name: f.name));
    await _reload();
  }

  Future<void> _up(int toLength) async {
    _path.removeRange(toLength, _path.length);
    await _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _browse(reset: true);
    } catch (e) {
      _error = friendlyError(e);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _more() async {
    setState(() => _loadingMore = true);
    try {
      await _browse();
    } catch (e) {
      _snack(friendlyError(e), ok: false);
    }
    if (mounted) setState(() => _loadingMore = false);
  }

  void _snack(String m, {bool ok = true}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(m), backgroundColor: ok ? AppColors.green700 : AppColors.filePdf));
  }

  Future<void> _copy(List<GoogleItem> items) async {
    if (items.isEmpty) return;
    final dest = await pickDriveFolder(context, _api,
        title: items.length == 1 ? 'Copy "${items.first.name}" to…' : 'Copy ${items.length} items to…',
        actionLabel: 'Copy here');
    if (dest == null) return;
    try {
      await _api.googleImport(items.map((i) => i.id).toList(), targetFolderId: dest == 'root' ? null : dest);
      if (!mounted) return;
      setState(() => _selected.clear());
      final n = items.length;
      _snack('Copying $n item${n == 1 ? '' : 's'} to Posta Drive — follow it in Settings → Imports on the web.');
      // The copies land in a moment; drop cached listings so they show up.
      try {
        context.read<DriveCache>().clearFolderCache(dest == 'root' ? null : dest);
      } catch (_) {}
    } catch (e) {
      _snack('Could not start the copy: ${friendlyError(e)}', ok: false);
    }
  }

  // ── UI ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 600;
    final pad = EdgeInsets.symmetric(horizontal: isMobile ? 12 : 24, vertical: 12);
    if (_loading && _conn == null) {
      return const Center(child: CircularProgressIndicator(color: AppColors.green700, strokeWidth: 2));
    }
    final conn = _conn;
    if (conn == null) return _message(Icons.cloud_off, _error ?? 'Could not load Google Drive.', retry: true);
    if (!conn.configured) {
      return _message(Icons.cloud_off, 'Google Drive isn’t available on this server yet — ask your administrator.');
    }
    if (!conn.connected) return _notConnected();

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: pad,
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          alignment: WrapAlignment.spaceBetween,
          children: [
            Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              const Text('Google Drive', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.heading)),
              if (conn.email != null && conn.email!.isNotEmpty)
                Text('Connected as ${conn.email}', style: const TextStyle(fontSize: 12, color: AppColors.muted)),
            ]),
            Row(mainAxisSize: MainAxisSize.min, children: [
              OutlinedButton.icon(
                onPressed: () => _webOnly('Add from Google Drive', 'Add from Google Drive'),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add from Google Drive'),
              ),
              IconButton(tooltip: 'Refresh', onPressed: _reload, icon: const Icon(Icons.refresh, color: AppColors.azure47)),
            ]),
          ],
        ),
      ),
      if (_path.isNotEmpty) _breadcrumb(pad),
      if (_selected.isNotEmpty) _selectionBar(pad),
      const Divider(height: 1),
      Expanded(child: _list()),
    ]);
  }

  Widget _breadcrumb(EdgeInsets pad) => Padding(
        padding: EdgeInsets.only(left: pad.left - 8, right: pad.right, bottom: 4),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            IconButton(
              tooltip: 'Back',
              icon: const Icon(Icons.arrow_back, size: 20),
              onPressed: () => _up(_path.length - 1),
            ),
            TextButton(onPressed: () => _up(0), child: const Text('Google Drive')),
            for (var i = 0; i < _path.length; i++) ...[
              const Icon(Icons.chevron_right, size: 16, color: AppColors.muted),
              TextButton(
                onPressed: i == _path.length - 1 ? null : () => _up(i + 1),
                child: Text(_path[i].name, overflow: TextOverflow.ellipsis),
              ),
            ],
          ]),
        ),
      );

  Widget _selectionBar(EdgeInsets pad) => Container(
        color: AppColors.greenActiveBg,
        padding: EdgeInsets.symmetric(horizontal: pad.left, vertical: 6),
        child: Row(children: [
          Text('${_selected.length} selected', style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.heading)),
          const Spacer(),
          TextButton(onPressed: () => setState(_selected.clear), child: const Text('Clear')),
          const SizedBox(width: 4),
          ElevatedButton.icon(
            onPressed: () => _copy(_items.where((i) => _selected.contains(i.id)).toList()),
            icon: const Icon(Icons.drive_folder_upload, size: 18),
            label: const Text('Copy to Posta Drive'),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.green700, foregroundColor: AppColors.white),
          ),
        ]),
      );

  Widget _list() {
    if (_loading) return const Center(child: CircularProgressIndicator(color: AppColors.green700, strokeWidth: 2));
    if (_error != null) return _message(Icons.error_outline, _error!, retry: true);
    if (_items.isEmpty) {
      return _message(
        Icons.add_to_drive,
        _path.isEmpty
            ? 'Nothing from Google Drive yet. Use “Add from Google Drive” to choose files and folders.'
            : 'This folder is empty, or Google didn’t give access to what’s inside.',
      );
    }
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.separated(
        itemCount: _items.length + (_next.isNotEmpty ? 1 : 0),
        separatorBuilder: (_, __) => const Divider(height: 1, indent: 64),
        itemBuilder: (_, i) {
          if (i == _items.length) {
            return Padding(
              padding: const EdgeInsets.all(12),
              child: Center(
                child: _loadingMore
                    ? const CircularProgressIndicator(strokeWidth: 2, color: AppColors.green700)
                    : TextButton(onPressed: _more, child: const Text('Load more')),
              ),
            );
          }
          return _row(_items[i]);
        },
      ),
    );
  }

  Widget _row(GoogleItem f) {
    final selected = _selected.contains(f.id);
    final sub = [
      if (f.modifiedAt != null) DateFormat('MMM d, y').format(f.modifiedAt!.toLocal()),
      if (!f.isFolder && f.size > 0) _size(f.size),
    ].join('  ·  ');
    return ListTile(
      selected: selected,
      selectedTileColor: AppColors.greenActiveBg,
      leading: Row(mainAxisSize: MainAxisSize.min, children: [
        Checkbox(
          value: selected,
          activeColor: AppColors.green700,
          onChanged: (v) => setState(() => v == true ? _selected.add(f.id) : _selected.remove(f.id)),
        ),
        Icon(_icon(f), color: _iconColor(f), size: 26),
      ]),
      title: Text(f.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, color: AppColors.heading)),
      subtitle: sub.isEmpty ? null : Text(sub, style: const TextStyle(fontSize: 11, color: AppColors.muted)),
      onTap: () => f.isFolder ? _enter(f) : _launch(Uri.parse(f.webViewLink)),
      trailing: PopupMenuButton<String>(
        icon: const Icon(Icons.more_horiz, color: AppColors.muted),
        onSelected: (v) {
          switch (v) {
            case 'open':
              f.isFolder ? _enter(f) : _launch(Uri.parse(f.webViewLink));
            case 'google':
              _launch(Uri.parse(f.webViewLink));
            case 'copy':
              _copy([f]);
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(
              value: 'open',
              child: Row(children: [
                const Icon(Icons.open_in_new, size: 16, color: AppColors.body),
                const SizedBox(width: 8),
                Text(f.isFolder ? 'Open' : 'Open in Google'),
              ])),
          if (f.isFolder)
            const PopupMenuItem(
                value: 'google',
                child: Row(children: [Icon(Icons.public, size: 16, color: AppColors.body), SizedBox(width: 8), Text('Open in Google')])),
          const PopupMenuItem(
              value: 'copy',
              child: Row(children: [
                Icon(Icons.drive_folder_upload, size: 16, color: AppColors.body),
                SizedBox(width: 8),
                Text('Copy to Posta Drive'),
              ])),
        ],
      ),
    );
  }

  Widget _notConnected() => _message(
        Icons.add_to_drive,
        'Connect your Google account to open your Google Drive files here and copy them into Posta Drive. '
        'Connecting happens once, on the web.',
        action: ElevatedButton.icon(
          onPressed: () => _webOnly('Connect Google Drive', 'Connect Google Drive'),
          icon: const Icon(Icons.link, size: 18),
          label: const Text('Connect Google Drive'),
          style: ElevatedButton.styleFrom(backgroundColor: AppColors.green700, foregroundColor: AppColors.white),
        ),
        retry: true,
        retryLabel: 'I’ve connected — refresh',
      );

  Widget _message(IconData icon, String text, {Widget? action, bool retry = false, String retryLabel = 'Try again'}) =>
      Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 48, color: AppColors.azure84),
              const SizedBox(height: 12),
              Text(text, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.body, fontSize: 14)),
              if (action != null) ...[const SizedBox(height: 16), action],
              if (retry) ...[
                const SizedBox(height: 8),
                TextButton(onPressed: _load, child: Text(retryLabel)),
              ],
            ]),
          ),
        ),
      );

  static IconData _icon(GoogleItem f) {
    if (f.isFolder || f.mimeType == _googleFolderMime) return Icons.folder;
    final m = f.mimeType;
    if (m.contains('document') || m.contains('word')) return Icons.description;
    if (m.contains('spreadsheet') || m.contains('excel') || m.contains('csv')) return Icons.grid_on;
    if (m.contains('presentation') || m.contains('powerpoint')) return Icons.slideshow;
    if (m == 'application/pdf') return Icons.picture_as_pdf;
    if (m.startsWith('image/')) return Icons.image;
    if (m.startsWith('video/')) return Icons.movie;
    if (m.startsWith('audio/')) return Icons.audiotrack;
    return Icons.insert_drive_file;
  }

  static Color _iconColor(GoogleItem f) {
    if (f.isFolder) return AppColors.green800;
    final m = f.mimeType;
    if (m.contains('document') || m.contains('word')) return AppColors.fileDocx;
    if (m.contains('spreadsheet') || m.contains('excel') || m.contains('csv')) return AppColors.fileXlsx;
    if (m.contains('presentation') || m.contains('powerpoint')) return AppColors.filePptx;
    if (m == 'application/pdf') return AppColors.filePdf;
    if (m.startsWith('image/')) return AppColors.filePng;
    if (m.startsWith('video/') || m.startsWith('audio/')) return AppColors.fileMedia;
    return AppColors.fileDefault;
  }

  static String _size(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
