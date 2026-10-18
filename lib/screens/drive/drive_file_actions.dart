// drive_file_actions.dart — per-file actions shared with the web's right-click
// menu: Tags, Send by email, Export as …, Print.

import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';

import '../../config/theme.dart';
import '../../models/drive_file.dart';
import '../../services/drive/drive_account_manager.dart';
import '../../services/drive/drive_api.dart';
import '../../services/drive/drive_client.dart';
import 'drive_open_file.dart';

DriveApi _api(BuildContext c) => c.read<DriveAccountManager>().activeApi!;

void _snack(BuildContext c, String m, {bool err = false}) {
  ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m), backgroundColor: err ? AppColors.filePdf : AppColors.green700));
}

/// Parses a tag colour ("#4f46e5" / "rgb(…)" unsupported → accent).
Color driveTagColor(String css) {
  var h = css.trim();
  if (h.startsWith('#')) h = h.substring(1);
  if (h.length == 3) h = h.split('').map((c) => '$c$c').join();
  final v = h.length == 6 ? int.tryParse(h, radix: 16) : null;
  return v == null ? AppColors.green700 : Color(0xFF000000 | v);
}

// ── Tags ────────────────────────────────────────────────────────────────────

/// Shows the file's tags; toggle any of your tags or create a new one.
Future<void> showDriveTagsSheet(BuildContext context, DriveFile file, {DriveApi? api}) {
  final a = api ?? _api(context);
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: _TagsSheet(api: a, file: file),
    ),
  );
}

class _TagsSheet extends StatefulWidget {
  final DriveApi api;
  final DriveFile file;
  const _TagsSheet({required this.api, required this.file});
  @override
  State<_TagsSheet> createState() => _TagsSheetState();
}

class _TagsSheetState extends State<_TagsSheet> {
  List<DriveTag> _all = [];
  Set<String> _attached = {};
  bool _loading = true;
  bool _busy = false;
  final _filter = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await Future.wait([widget.api.listTags(), widget.api.fileTags(widget.file.id)]);
      _all = r[0];
      _attached = r[1].map((t) => t.id).toSet();
    } catch (e) {
      if (mounted) _snack(context, 'Could not load tags: ${friendlyError(e)}', err: true);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _toggle(DriveTag t) async {
    final on = _attached.contains(t.id);
    setState(() => _busy = true);
    try {
      if (on) {
        await widget.api.detachTag(widget.file.id, t.id);
        _attached.remove(t.id);
      } else {
        await widget.api.attachTag(widget.file.id, t.id);
        _attached.add(t.id);
      }
    } catch (e) {
      if (mounted) _snack(context, friendlyError(e), err: true);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _create() async {
    final name = _filter.text.trim();
    if (name.isEmpty) return;
    setState(() => _busy = true);
    try {
      final t = await widget.api.createTag(name);
      await widget.api.attachTag(widget.file.id, t.id);
      _all = [..._all, t];
      _attached.add(t.id);
      _filter.clear();
    } catch (e) {
      if (mounted) _snack(context, friendlyError(e), err: true);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final q = _filter.text.trim().toLowerCase();
    final list = _all.where((t) => q.isEmpty || t.name.toLowerCase().contains(q)).toList();
    final canCreate = q.isNotEmpty && !_all.any((t) => t.name.toLowerCase() == q);
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.6,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.sell_outlined, color: AppColors.green800, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Tags for ${widget.file.name}',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.heading)),
              ),
              if (_busy) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.green700)),
            ]),
            const SizedBox(height: 12),
            TextField(
              controller: _filter,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => canCreate ? _create() : null,
              decoration: InputDecoration(
                hintText: 'Find or create a tag',
                prefixIcon: const Icon(Icons.search, size: 20),
                filled: true,
                fillColor: AppColors.grey96,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
              ),
            ),
            const SizedBox(height: 8),
            if (canCreate)
              ListTile(
                dense: true,
                leading: const Icon(Icons.add, color: AppColors.green700),
                title: Text('Create “${_filter.text.trim()}”'),
                onTap: _busy ? null : _create,
              ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator(color: AppColors.green700, strokeWidth: 2))
                  : list.isEmpty
                      ? const Center(child: Text('No tags yet — type a name to create one.', style: TextStyle(color: AppColors.muted)))
                      : ListView(
                          children: [
                            for (final t in list)
                              CheckboxListTile(
                                dense: true,
                                value: _attached.contains(t.id),
                                activeColor: AppColors.green700,
                                onChanged: _busy ? null : (_) => _toggle(t),
                                secondary: CircleAvatar(radius: 7, backgroundColor: driveTagColor(t.color)),
                                title: Text(t.name),
                              ),
                          ],
                        ),
            ),
          ]),
        ),
      ),
    );
  }
}

// ── Send by email ─────────────────────────────────────────────────────────────

/// Queue an email with the file (attached by default); the recipient needs no
/// Posta Drive account.
Future<void> showDriveEmailDialog(BuildContext context, DriveFile file, {DriveApi? api}) async {
  final a = api ?? _api(context);
  final to = TextEditingController();
  final subject = TextEditingController();
  final body = TextEditingController();
  var attach = true;
  var busy = false;
  String? err;
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) {
        Future<void> send() async {
          final addr = to.text.trim();
          if (!addr.contains('@')) {
            setS(() => err = 'Enter a valid recipient email.');
            return;
          }
          setS(() {
            busy = true;
            err = null;
          });
          try {
            await a.emailFile(file.id, to: addr, subject: subject.text.trim(), body: body.text.trim(), attach: attach);
            if (ctx.mounted) Navigator.pop(ctx);
            if (context.mounted) _snack(context, 'Email to $addr queued');
          } catch (e) {
            setS(() {
              busy = false;
              err = friendlyError(e);
            });
          }
        }

        return AlertDialog(
          scrollable: true,
          title: Text('Send "${file.name}" by email', overflow: TextOverflow.ellipsis),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: to,
                autofocus: true,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'To', hintText: 'recipient@example.com'),
              ),
              TextField(
                controller: subject,
                decoration: InputDecoration(labelText: 'Subject', hintText: 'Shared via Posta Drive: ${file.name}'),
              ),
              TextField(
                controller: body,
                minLines: 3,
                maxLines: 6,
                decoration: const InputDecoration(labelText: 'Message', hintText: 'Optional note (visible to the recipient)'),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: attach,
                activeColor: AppColors.green700,
                onChanged: (v) => setS(() => attach = v ?? true),
                title: const Text('Attach the file', style: TextStyle(fontSize: 14)),
              ),
              if (err != null) Text(err!, style: const TextStyle(color: AppColors.filePdf, fontSize: 13)),
            ]),
          ),
          actions: [
            TextButton(onPressed: busy ? null : () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: busy ? null : send,
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.green700, foregroundColor: AppColors.white),
              child: Text(busy ? 'Sending…' : 'Send'),
            ),
          ],
        );
      },
    ),
  );
  to.dispose();
  subject.dispose();
  body.dispose();
}

// ── Export as … ─────────────────────────────────────────────────────────────

/// Convert [file] to [format] on the server and save it where the user picks.
Future<void> exportDriveFile(BuildContext context, DriveFile file, String format) async {
  final api = _api(context);
  _snack(context, 'Exporting ${file.name}…');
  try {
    final bytes = await api.convert(file.id, format);
    final base = file.name.contains('.') ? file.name.substring(0, file.name.lastIndexOf('.')) : file.name;
    final name = '$base.$format';
    final isMobile = Platform.isIOS || Platform.isAndroid;
    final path = await FilePicker.platform.saveFile(dialogTitle: 'Save $name', fileName: name, bytes: isMobile ? bytes : null);
    if (path == null) return;
    if (!isMobile) await File(path).writeAsBytes(bytes);
    if (context.mounted) _snack(context, '"$name" saved');
  } catch (e) {
    if (context.mounted) _snack(context, 'Export failed: ${friendlyError(e)}', err: true);
  }
}

// ── Print ───────────────────────────────────────────────────────────────────

const _printableImages = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'};

/// Office files (via their PDF preview), PDFs and images can be printed.
bool canPrintDriveFile(DriveFile f) =>
    !f.isDirectory && (isDriveOfficeFile(f) || f.extension == 'pdf' || _printableImages.contains(f.extension));

/// Opens the system print dialog for [file].
Future<void> printDriveFile(BuildContext context, DriveFile file) async {
  final api = _api(context);
  try {
    Uint8List pdf;
    if (isDriveOfficeFile(file)) {
      // The server's PDF preview is made in the background; until it exists
      // (e.g. a file just created) convert on demand instead.
      try {
        pdf = await api.previewPdf(file.id);
      } on DriveException catch (e) {
        if (!e.isNotFound) rethrow;
        pdf = await api.convert(file.id, 'pdf');
      }
    } else if (file.extension == 'pdf') {
      pdf = await api.download(file.id);
    } else {
      final img = pw.MemoryImage(await api.download(file.id));
      final doc = pw.Document()
        ..addPage(pw.Page(pageFormat: PdfPageFormat.a4, build: (_) => pw.Center(child: pw.Image(img, fit: pw.BoxFit.contain))));
      pdf = await doc.save();
    }
    await Printing.layoutPdf(name: file.name, onLayout: (_) async => pdf);
  } catch (e) {
    if (context.mounted) _snack(context, 'Could not print: ${friendlyError(e)}', err: true);
  }
}
