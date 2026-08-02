// drive_file_preview.dart — file preview for the new Drive.
//
// Renders images, text, PDFs, and audio inline; anything else downloads and
// opens with the system app. Content streams via the active account's DriveApi.

import 'dart:convert';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';

import '../../config/theme.dart';
import '../../models/drive_file.dart';
import '../../services/drive/drive_account_manager.dart';
import '../../services/drive/drive_api.dart';
import '../../services/drive/drive_client.dart';
import 'drive_office_editor.dart';

class DriveFilePreview extends StatefulWidget {
  final DriveFile file;
  const DriveFilePreview({super.key, required this.file});

  @override
  State<DriveFilePreview> createState() => _DriveFilePreviewState();
}

class _DriveFilePreviewState extends State<DriveFilePreview> {
  Uint8List? _bytes;
  bool _loading = true;
  String? _error;
  AudioPlayer? _audio;
  Duration _dur = Duration.zero;
  Duration _pos = Duration.zero;
  bool _playing = false;

  // Text editing (mirrors the Drive's CodeMirror editor: load content, edit,
  // PUT /content on save → new version; edit-in-place, no autosave spam).
  bool _editing = false;
  bool _saving = false;
  TextEditingController? _textCtrl;
  String _originalText = '';
  static const _textEditMaxBytes = 5 * 1024 * 1024; // matches the Drive's 5 MB cap
  bool get _dirty => _textCtrl != null && _textCtrl!.text != _originalText;
  bool get _canEditText => _isText && widget.file.writable && (_bytes == null || _bytes!.length <= _textEditMaxBytes);

  static const _image = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'ico'};
  static const _text = {
    'txt', 'md', 'json', 'xml', 'yaml', 'yml', 'log', 'csv', 'tsv', 'html', 'htm',
    'css', 'js', 'ts', 'dart', 'py', 'java', 'c', 'cpp', 'h', 'sh', 'sql', 'go', 'rs', 'svg',
  };
  static const _audioExt = {'mp3', 'wav', 'aac', 'ogg', 'flac', 'm4a', 'opus'};
  static const _officeExt = {'docx', 'xlsx', 'pptx', 'doc', 'xls', 'ppt', 'odt', 'ods', 'odp'};

  String get _ext => widget.file.extension;
  bool get _isImage => _image.contains(_ext);
  bool get _isText => _text.contains(_ext);
  bool get _isPdf => _ext == 'pdf';
  bool get _isAudio => _audioExt.contains(_ext);
  bool get _isOffice => _officeExt.contains(_ext);
  bool get _inlineable => _isImage || _isText || _isPdf || _isAudio;

  @override
  void initState() {
    super.initState();
    if (_inlineable) {
      _load();
    } else {
      _loading = false;
    }
  }

  @override
  void dispose() {
    _audio?.dispose();
    _textCtrl?.dispose();
    super.dispose();
  }

  void _enterEdit() {
    setState(() {
      _textCtrl ??= TextEditingController(text: _originalText);
      _textCtrl!.text = _originalText;
      _editing = true;
    });
  }

  Future<void> _exitEdit() async {
    if (_dirty) await _saveText(); // mirror the Drive's save-on-blur
    if (mounted) setState(() => _editing = false);
  }

  Future<void> _saveText() async {
    if (_textCtrl == null || _saving || !_dirty) return;
    setState(() => _saving = true);
    try {
      final text = _textCtrl!.text;
      final bytes = utf8.encode(text);
      // Same request the Drive makes: PUT /files/{id}/content, mime = file's
      // own type (fallback text/plain). Creates a new version server-side.
      await _api.replaceContent(widget.file.id, bytes, contentType: widget.file.mimeType ?? 'text/plain');
      if (mounted) {
        setState(() {
          _originalText = text;
          _bytes = Uint8List.fromList(bytes);
          _saving = false;
        });
        _snack('Saved');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        _snack('Save failed: ${friendlyError(e)}', err: true);
      }
    }
  }

  Future<void> _load() async {
    try {
      final api = context.read<DriveAccountManager>().activeApi!;
      final bytes = await api.download(widget.file.id);
      if (!mounted) return;
      if (_isText) _originalText = utf8.decode(bytes, allowMalformed: true);
      setState(() { _bytes = bytes; _loading = false; });
      if (_isAudio) _initAudio(bytes);
    } catch (e) {
      if (mounted) setState(() { _error = friendlyError(e); _loading = false; });
    }
  }

  Future<void> _initAudio(Uint8List bytes) async {
    try {
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/${widget.file.name}');
      await f.writeAsBytes(bytes);
      final p = AudioPlayer();
      p.onDurationChanged.listen((d) { if (mounted) setState(() => _dur = d); });
      p.onPositionChanged.listen((d) { if (mounted) setState(() => _pos = d); });
      p.onPlayerStateChanged.listen((s) { if (mounted) setState(() => _playing = s == PlayerState.playing); });
      await p.setSourceDeviceFile(f.path);
      _audio = p;
    } catch (_) {}
  }

  Future<void> _download() async {
    try {
      final api = context.read<DriveAccountManager>().activeApi!;
      final bytes = _bytes ?? await api.download(widget.file.id);
      final isMobile = Platform.isIOS || Platform.isAndroid;
      final path = await FilePicker.platform.saveFile(dialogTitle: 'Save ${widget.file.name}', fileName: widget.file.name, bytes: isMobile ? bytes : null);
      if (path == null) return;
      if (!isMobile) await File(path).writeAsBytes(bytes);
      _snack('"${widget.file.name}" saved');
    } catch (e) {
      _snack('Download failed: ${friendlyError(e)}', err: true);
    }
  }

  Future<void> _openWithSystem() async {
    try {
      final api = context.read<DriveAccountManager>().activeApi!;
      final bytes = _bytes ?? await api.download(widget.file.id);
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/${widget.file.name}');
      await f.writeAsBytes(bytes);
      await OpenFilex.open(f.path);
    } catch (e) {
      _snack('Could not open: ${friendlyError(e)}', err: true);
    }
  }

  void _snack(String m, {bool err = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), backgroundColor: err ? AppColors.filePdf : AppColors.green700));
  }

  DriveApi get _api => context.read<DriveAccountManager>().activeApi!;

  void _showVersions() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => FutureBuilder<List<DriveVersion>>(
        future: _api.listVersions(widget.file.id),
        builder: (ctx, snap) => Container(
          height: MediaQuery.of(ctx).size.height * 0.6,
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Row(children: [Icon(Icons.history, color: AppColors.green800, size: 20), SizedBox(width: 8), Text('Version history', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.heading))]),
            const SizedBox(height: 12),
            const Divider(),
            Expanded(
              child: snap.connectionState == ConnectionState.waiting
                  ? const Center(child: CircularProgressIndicator(color: AppColors.green700))
                  : (snap.data?.isEmpty ?? true)
                      ? const Center(child: Text('No versions', style: TextStyle(color: AppColors.muted)))
                      : ListView(children: snap.data!.map((v) => ListTile(
                            dense: true,
                            leading: Icon(v.isCurrent ? Icons.check_circle : Icons.history, size: 20, color: v.isCurrent ? AppColors.green700 : AppColors.muted),
                            title: Text(v.label ?? (v.createdAt != null ? DateFormat('MMM d, y  h:mm a').format(v.createdAt!.toLocal()) : v.id.substring(0, 8)), style: const TextStyle(fontSize: 13)),
                            subtitle: Text('${(v.sizeBytes / 1024).toStringAsFixed(1)} KB${v.isCurrent ? ' · current' : ''}', style: const TextStyle(fontSize: 11, color: AppColors.muted)),
                            trailing: v.isCurrent
                                ? null
                                : TextButton(
                                    onPressed: () async {
                                      Navigator.pop(ctx);
                                      try {
                                        await _api.restoreVersion(widget.file.id, v.id);
                                        _snack('Version restored');
                                        setState(() { _loading = true; _bytes = null; });
                                        if (_inlineable) _load();
                                      } catch (e) {
                                        _snack('Restore failed: ${friendlyError(e)}', err: true);
                                      }
                                    },
                                    child: const Text('Restore'),
                                  ),
                          )).toList()),
            ),
          ]),
        ),
      ),
    );
  }

  void _showComments() {
    final ctrl = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: StatefulBuilder(builder: (ctx, setSheet) {
          Future<List<DriveComment>> load() => _api.listComments(widget.file.id);
          var future = load();
          return SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.6,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Row(children: [Icon(Icons.comment_outlined, color: AppColors.green800, size: 20), SizedBox(width: 8), Text('Comments', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.heading))]),
                const SizedBox(height: 8),
                const Divider(),
                Expanded(
                  child: FutureBuilder<List<DriveComment>>(
                    future: future,
                    builder: (ctx, snap) => snap.connectionState == ConnectionState.waiting
                        ? const Center(child: CircularProgressIndicator(color: AppColors.green700))
                        : (snap.data?.isEmpty ?? true)
                            ? const Center(child: Text('No comments yet', style: TextStyle(color: AppColors.muted)))
                            : ListView(children: snap.data!.map((c) => Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 8),
                                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    CircleAvatar(radius: 14, backgroundColor: AppColors.green700, child: Text(c.authorName.isNotEmpty ? c.authorName[0].toUpperCase() : '?', style: const TextStyle(color: AppColors.white, fontSize: 11))),
                                    const SizedBox(width: 10),
                                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                      Text(c.authorName, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.heading)),
                                      Text(c.body, style: const TextStyle(fontSize: 13, color: AppColors.body)),
                                    ])),
                                  ]),
                                )).toList()),
                  ),
                ),
                Row(children: [
                  Expanded(child: TextField(controller: ctrl, decoration: InputDecoration(hintText: 'Add a comment…', filled: true, fillColor: AppColors.grey96, border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none), contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10)))),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.send, color: AppColors.green700),
                    onPressed: () async {
                      final body = ctrl.text.trim();
                      if (body.isEmpty) return;
                      ctrl.clear();
                      try {
                        await _api.addComment(widget.file.id, body);
                        setSheet(() { future = load(); });
                      } catch (e) {
                        _snack('Comment failed: ${friendlyError(e)}', err: true);
                      }
                    },
                  ),
                ]),
              ]),
            ),
          );
        }),
      ),
    );
  }

  String _fmtDur(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final scaffold = Scaffold(
      backgroundColor: AppColors.grey98,
      appBar: AppBar(
        title: Row(children: [
          Flexible(child: Text(widget.file.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
          if (_editing && _dirty) const Padding(padding: EdgeInsets.only(left: 6), child: Icon(Icons.circle, size: 8, color: AppColors.away)),
        ]),
        backgroundColor: AppColors.white,
        foregroundColor: AppColors.heading,
        elevation: 0,
        actions: [
          // Text edit controls (mirror the Drive's editor).
          if (_isText && _editing)
            _saving
                ? const Padding(padding: EdgeInsets.symmetric(horizontal: 14), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.green700)))
                : IconButton(icon: const Icon(Icons.save, color: AppColors.green700), tooltip: 'Save (⌘/Ctrl+S)', onPressed: _dirty ? _saveText : null),
          if (_canEditText)
            IconButton(
              icon: Icon(_editing ? Icons.edit_off : Icons.edit, color: _editing ? AppColors.green800 : AppColors.azure47),
              tooltip: _editing ? 'Stop editing' : 'Edit',
              onPressed: () => _editing ? _exitEdit() : _enterEdit(),
            ),
          IconButton(icon: const Icon(Icons.history, color: AppColors.azure47), tooltip: 'Version history', onPressed: _showVersions),
          IconButton(icon: const Icon(Icons.comment_outlined, color: AppColors.azure47), tooltip: 'Comments', onPressed: _showComments),
          IconButton(icon: const Icon(Icons.open_in_new, color: AppColors.azure47), tooltip: 'Open with…', onPressed: _openWithSystem),
          IconButton(icon: const Icon(Icons.download, color: AppColors.azure47), tooltip: 'Download', onPressed: _download),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.green700))
          : _error != null
              ? _errorView()
              : _preview(),
    );

    // Cmd/Ctrl+S saves while editing; guard against losing unsaved changes on back.
    return PopScope(
      canPop: !(_editing && _dirty),
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final nav = Navigator.of(context);
        final save = await _confirmDiscard();
        if (save == null) return; // stay
        if (save) await _saveText();
        if (mounted) nav.pop();
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () { if (_editing) _saveText(); },
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): () { if (_editing) _saveText(); },
        },
        child: Focus(autofocus: false, child: scaffold),
      ),
    );
  }

  Future<bool?> _confirmDiscard() => showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Unsaved changes'),
          content: const Text('Save your changes before leaving?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Keep editing')),
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Discard')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        ),
      );

  Widget _errorView() => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.error_outline, size: 48, color: AppColors.filePdf),
          const SizedBox(height: 16),
          Text(_error!, style: const TextStyle(color: AppColors.body)),
          const SizedBox(height: 16),
          ElevatedButton(onPressed: () { setState(() { _loading = true; _error = null; }); _load(); }, child: const Text('Retry')),
        ]),
      );

  Widget _preview() {
    if (_isPdf && _bytes != null) return SfPdfViewer.memory(_bytes!);
    if (_isImage && _bytes != null) {
      return InteractiveViewer(minScale: 0.5, maxScale: 5, child: Center(child: Image.memory(_bytes!, fit: BoxFit.contain)));
    }
    if (_isText && _bytes != null) {
      const style = TextStyle(fontSize: 13, fontFamily: 'monospace', color: AppColors.heading, height: 1.5);
      if (_editing && _textCtrl != null) {
        return Container(
          color: const Color(0xFFFAFAFA),
          child: TextField(
            controller: _textCtrl,
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            keyboardType: TextInputType.multiline,
            style: style,
            onChanged: (_) => setState(() {}), // refresh dirty state
            decoration: const InputDecoration(
              border: InputBorder.none,
              filled: false,
              isDense: true,
              contentPadding: EdgeInsets.all(16),
            ),
          ),
        );
      }
      return Container(
        color: const Color(0xFFFAFAFA),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: SelectableText(utf8.decode(_bytes!, allowMalformed: true), style: style),
        ),
      );
    }
    if (_isAudio) return _audioView();
    if (_isOffice) return _officeView();
    return _unsupportedView();
  }

  Widget _officeView() => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(color: AppColors.filePsd.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(16)),
            child: const Icon(Icons.edit_document, size: 40, color: AppColors.filePsd),
          ),
          const SizedBox(height: 16),
          Text(widget.file.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.heading), textAlign: TextAlign.center),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () => Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => DriveOfficeEditor(file: widget.file))),
            icon: const Icon(Icons.open_in_new, size: 18),
            // Viewers get read-only Office Online (WOPI enforces it server-side) —
            // don't mislabel it "Edit".
            label: Text(widget.file.writable ? 'Edit in Office Online' : 'Open in Office Online'),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.green800, foregroundColor: AppColors.white),
          ),
        ]),
      );

  Widget _audioView() => Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 400),
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 120, height: 120, decoration: BoxDecoration(color: AppColors.greenActiveBg, borderRadius: BorderRadius.circular(60)), child: const Icon(Icons.music_note, size: 56, color: AppColors.green800)),
            const SizedBox(height: 24),
            Text(widget.file.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.heading), textAlign: TextAlign.center),
            const SizedBox(height: 16),
            Slider(
              value: _dur.inMilliseconds > 0 ? (_pos.inMilliseconds / _dur.inMilliseconds).clamp(0.0, 1.0) : 0,
              activeColor: AppColors.green700,
              onChanged: (v) => _audio?.seek(Duration(milliseconds: (v * _dur.inMilliseconds).round())),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text(_fmtDur(_pos), style: const TextStyle(fontSize: 12, color: AppColors.muted)),
                Text(_fmtDur(_dur), style: const TextStyle(fontSize: 12, color: AppColors.muted)),
              ]),
            ),
            const SizedBox(height: 16),
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(color: AppColors.green800, borderRadius: BorderRadius.circular(32)),
              child: IconButton(
                icon: Icon(_playing ? Icons.pause : Icons.play_arrow, size: 32),
                color: AppColors.white,
                onPressed: () => _playing ? _audio?.pause() : _audio?.resume(),
              ),
            ),
          ]),
        ),
      );

  Widget _unsupportedView() => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.insert_drive_file, size: 64, color: AppColors.muted),
          const SizedBox(height: 16),
          Text(widget.file.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.heading), textAlign: TextAlign.center),
          const SizedBox(height: 4),
          Text('${_ext.toUpperCase()} file  ·  ${widget.file.sizeFormatted}', style: const TextStyle(fontSize: 14, color: AppColors.body)),
          const SizedBox(height: 24),
          const Text('No inline preview for this type.', style: TextStyle(color: AppColors.muted, fontSize: 13)),
          const SizedBox(height: 16),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            ElevatedButton.icon(onPressed: _openWithSystem, icon: const Icon(Icons.open_in_new, size: 18), label: const Text('Open with…'), style: ElevatedButton.styleFrom(backgroundColor: AppColors.green800, foregroundColor: AppColors.white)),
            const SizedBox(width: 12),
            OutlinedButton.icon(onPressed: _download, icon: const Icon(Icons.download, size: 18), label: const Text('Download'), style: OutlinedButton.styleFrom(foregroundColor: AppColors.green700)),
          ]),
        ]),
      );
}
