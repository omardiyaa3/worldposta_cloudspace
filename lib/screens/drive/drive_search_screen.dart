// drive_search_screen.dart — full-text search results (GET /search).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../config/theme.dart';
import '../../models/drive_file.dart';
import '../../services/drive/drive_account_manager.dart';
import '../../services/drive/drive_api.dart';
import '../../services/drive/drive_client.dart';
import '../../widgets/file_type_badge.dart';
import 'drive_file_preview.dart';

/// Live search results, rendered inline in the shell's content area (no Scaffold)
/// so the persistent top-bar search field stays focused while typing. Re-runs the
/// query whenever [query] changes; a request token guards against out-of-order
/// responses when the user types faster than the network replies.
class DriveSearchResults extends StatefulWidget {
  final String query;
  const DriveSearchResults({super.key, required this.query});

  @override
  State<DriveSearchResults> createState() => _DriveSearchResultsState();
}

class _DriveSearchResultsState extends State<DriveSearchResults> {
  List<DriveSearchHit> _hits = [];
  bool _loading = true;
  String? _error;
  int _reqId = 0;

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void didUpdateWidget(DriveSearchResults old) {
    super.didUpdateWidget(old);
    if (old.query != widget.query) _run();
  }

  Future<void> _run() async {
    final id = ++_reqId;
    setState(() { _loading = true; _error = null; });
    try {
      final api = context.read<DriveAccountManager>().activeApi!;
      final hits = await api.search(widget.query);
      if (mounted && id == _reqId) setState(() { _hits = hits; _loading = false; });
    } catch (e) {
      if (mounted && id == _reqId) {
        setState(() { _error = friendlyError(e); _loading = false; });
      }
    }
  }

  void _open(DriveSearchHit h) {
    final f = DriveFile(id: h.id, isDirectory: h.isDirectory, name: h.name, sizeBytes: h.sizeBytes, mimeType: h.mimeType);
    if (!f.isDirectory) {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => DriveFilePreview(file: f)));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _hits.isEmpty) {
      return const Center(child: CircularProgressIndicator(color: AppColors.green700));
    }
    if (_error != null) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.search_off, size: 48, color: AppColors.muted),
        const SizedBox(height: 12),
        Text(_error!, style: const TextStyle(color: AppColors.body), textAlign: TextAlign.center),
      ]));
    }
    if (_hits.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.search_off, size: 64, color: AppColors.muted),
        const SizedBox(height: 16),
        Text('No results for "${widget.query}"', style: const TextStyle(color: AppColors.body, fontSize: 16)),
      ]));
    }
    return Column(children: [
      // A thin progress line while re-querying keeps the results visible (no flash).
      SizedBox(height: 2, child: _loading ? const LinearProgressIndicator(minHeight: 2, color: AppColors.green700, backgroundColor: AppColors.grey96) : null),
      Expanded(
        child: ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: _hits.length,
          separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.grey91),
          itemBuilder: (_, i) {
            final h = _hits[i];
            final ext = h.name.contains('.') ? h.name.split('.').last : '';
            return ListTile(
              leading: FileIcon(extension: ext, isDirectory: h.isDirectory, size: 32),
              title: Text(h.name, overflow: TextOverflow.ellipsis),
              subtitle: h.snippet.isNotEmpty ? Text(h.snippet, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)) : null,
              onTap: () => _open(h),
            );
          },
        ),
      ),
    ]);
  }
}

class DriveSearchScreen extends StatefulWidget {
  final String query;
  const DriveSearchScreen({super.key, required this.query});

  @override
  State<DriveSearchScreen> createState() => _DriveSearchScreenState();
}

class _DriveSearchScreenState extends State<DriveSearchScreen> {
  List<DriveSearchHit> _hits = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() { _loading = true; _error = null; });
    try {
      final api = context.read<DriveAccountManager>().activeApi!;
      final hits = await api.search(widget.query);
      if (mounted) setState(() { _hits = hits; _loading = false; });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = friendlyError(e);
          _loading = false;
        });
      }
    }
  }

  void _open(DriveSearchHit h) {
    final f = DriveFile(id: h.id, isDirectory: h.isDirectory, name: h.name, sizeBytes: h.sizeBytes, mimeType: h.mimeType);
    if (!f.isDirectory) {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => DriveFilePreview(file: f)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.grey98,
      appBar: AppBar(
        title: Text('Search: "${widget.query}"', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        backgroundColor: AppColors.white,
        foregroundColor: AppColors.heading,
        elevation: 0,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.green700))
          : _error != null
              ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.search_off, size: 48, color: AppColors.muted),
                  const SizedBox(height: 12),
                  Text(_error!, style: const TextStyle(color: AppColors.body), textAlign: TextAlign.center),
                ]))
              : _hits.isEmpty
                  ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.search_off, size: 64, color: AppColors.muted),
                      const SizedBox(height: 16),
                      Text('No results for "${widget.query}"', style: const TextStyle(color: AppColors.body, fontSize: 16)),
                    ]))
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: _hits.length,
                      separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.grey91),
                      itemBuilder: (_, i) {
                        final h = _hits[i];
                        final ext = h.name.contains('.') ? h.name.split('.').last : '';
                        return ListTile(
                          leading: FileIcon(extension: ext, isDirectory: h.isDirectory, size: 32),
                          title: Text(h.name, overflow: TextOverflow.ellipsis),
                          subtitle: h.snippet.isNotEmpty ? Text(h.snippet, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)) : null,
                          onTap: () => _open(h),
                        );
                      },
                    ),
    );
  }
}
