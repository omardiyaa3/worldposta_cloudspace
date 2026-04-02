import 'dart:io';
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:spreadsheet_decoder/spreadsheet_decoder.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import '../../config/theme.dart';
import '../../models/nc_file.dart';
import '../../services/auth_service.dart';
import '../../services/webdav_service.dart';

class FilePreviewScreen extends StatefulWidget {
  final NcFile file;

  const FilePreviewScreen({super.key, required this.file});

  @override
  State<FilePreviewScreen> createState() => _FilePreviewScreenState();
}

class _FilePreviewScreenState extends State<FilePreviewScreen> {
  Uint8List? _bytes;
  bool _isLoading = true;
  String? _error;
  bool _isEditing = false;
  bool _hasUnsavedChanges = false;
  bool _isSaving = false;
  TextEditingController? _textController;
  String? _originalText;
  // Audio player
  AudioPlayer? _audioPlayer;
  Duration _audioDuration = Duration.zero;
  Duration _audioPosition = Duration.zero;
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    _loadFile();
  }

  Future<void> _loadFile() async {
    // Office docs: on Windows open in Edge app mode, others use in-app webview
    if (_isOfficeDoc || _isSpreadsheet || _isPresentation) {
      if (Platform.isWindows) {
        await _launchWindowsEditor();
        if (mounted) Navigator.of(context).pop();
        return;
      }
      if (mounted) setState(() => _isLoading = false);
      return;
    }
    try {
      final auth = context.read<AuthService>();
      final webdav = WebDavService(auth);
      final bytes = await webdav.downloadFile(widget.file.path);
      if (mounted) {
        setState(() { _bytes = bytes; _isLoading = false; });
        if (_isAudio) _initAudioPlayer(bytes);
      }
    } catch (e) {
      if (mounted) setState(() { _error = '$e'; _isLoading = false; });
    }
  }

  bool get _isImage {
    final ext = widget.file.extension.toLowerCase();
    return {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'ico'}.contains(ext);
  }

  bool get _isPdf => widget.file.extension.toLowerCase() == 'pdf';

  bool get _isText {
    final ext = widget.file.extension.toLowerCase();
    return {
      'txt', 'md', 'json', 'xml', 'yaml', 'yml', 'log', 'tsv',
      'html', 'htm', 'css', 'js', 'ts', 'jsx', 'tsx', 'dart', 'py', 'java',
      'c', 'cpp', 'h', 'hpp', 'sh', 'bash', 'zsh', 'conf', 'ini', 'env',
      'sql', 'rb', 'php', 'swift', 'kt', 'go', 'rs', 'r', 'lua', 'pl',
      'svg', 'tex', 'bib', 'toml', 'cfg', 'properties',
      'gitignore', 'dockerignore', 'dockerfile', 'makefile',
      'bat', 'cmd', 'ps1', 'vbs',
      'rtf', 'diff', 'patch',
      'ics', 'vcf', 'htaccess', 'nginx',
    }.contains(ext);
  }

  bool get _isAudio {
    final ext = widget.file.extension.toLowerCase();
    return {'mp3', 'wav', 'aac', 'ogg', 'flac', 'm4a', 'wma', 'opus'}.contains(ext);
  }

  bool get _isPresentation {
    final ext = widget.file.extension.toLowerCase();
    return {'pptx', 'ppt', 'odp', 'key'}.contains(ext);
  }

  bool get _isSpreadsheet {
    final ext = widget.file.extension.toLowerCase();
    return {'xlsx', 'xls', 'ods', 'csv'}.contains(ext);
  }

  bool get _isDrawio {
    return widget.file.extension.toLowerCase() == 'drawio';
  }

  bool get _isOfficeDoc {
    final ext = widget.file.extension.toLowerCase();
    return {'docx', 'doc', 'odt', 'odg'}.contains(ext);
  }

  @override
  void dispose() {
    _textController?.dispose();
    _audioPlayer?.dispose();
    super.dispose();
  }

  Future<void> _initAudioPlayer(Uint8List bytes) async {
    try {
      // Save to temp file for audio player
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/${widget.file.name}');
      await file.writeAsBytes(bytes);

      _audioPlayer = AudioPlayer();
      _audioPlayer!.onDurationChanged.listen((d) {
        if (mounted) setState(() => _audioDuration = d);
      });
      _audioPlayer!.onPositionChanged.listen((p) {
        if (mounted) setState(() => _audioPosition = p);
      });
      _audioPlayer!.onPlayerStateChanged.listen((state) {
        if (mounted) setState(() => _isPlaying = state == PlayerState.playing);
      });
      await _audioPlayer!.setSourceDeviceFile(file.path);
    } catch (e) {
      debugPrint('Audio player init failed: $e');
    }
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (d.inHours > 0) {
      return '${d.inHours}:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  Future<void> _launchWindowsEditor() async {
    final auth = context.read<AuthService>();
    final fileId = widget.file.fileId;
    if (fileId == null || fileId.isEmpty) return;

    final targetUrl = '${auth.serverUrl}/index.php/apps/files/files/$fileId?dir=/&openfile=true';
    final authedUri = Uri.parse(targetUrl).replace(
      userInfo: '${Uri.encodeComponent(auth.username!)}:${Uri.encodeComponent(auth.appPassword!)}',
    );

    try {
      final browsers = [
        'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
        'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
        'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
        'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
      ];
      String? browserPath;
      for (final p in browsers) {
        if (await File(p).exists()) { browserPath = p; break; }
      }

      if (browserPath != null) {
        await Process.start(browserPath, [
          '--app=${authedUri.toString()}',
          '--window-size=1200,800',
        ]);
      } else {
        await launchUrl(authedUri, mode: LaunchMode.externalApplication);
      }

      await Future.delayed(const Duration(seconds: 6));
    } catch (e) {
      await launchUrl(authedUri, mode: LaunchMode.externalApplication);
      await Future.delayed(const Duration(seconds: 6));
    }
  }

  Future<void> _saveFile() async {
    if (_textController == null || _isSaving) return;
    setState(() => _isSaving = true);
    try {
      final auth = context.read<AuthService>();
      final webdav = WebDavService(auth);
      final content = Uint8List.fromList(_textController!.text.codeUnits);
      await webdav.uploadFile(widget.file.path, content);
      if (mounted) {
        setState(() {
          _bytes = content;
          _originalText = _textController!.text;
          _hasUnsavedChanges = false;
          _isSaving = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('File saved'),
            backgroundColor: AppColors.green700,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSaving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Save failed: $e'),
            backgroundColor: AppColors.filePdf,
          ),
        );
      }
    }
  }

  final ScrollController _editorScrollController = ScrollController();

  Widget _buildCodeEditor({required bool editing}) {
    final text = editing
        ? (_textController?.text ?? String.fromCharCodes(_bytes!))
        : (_textController?.text ?? String.fromCharCodes(_bytes!));
    final lines = text.split('\n');
    final lineCount = lines.length;
    final lineNumWidth = '${lineCount}'.length * 9.0 + 16;

    const textStyle = TextStyle(
      fontSize: 13,
      fontFamily: 'monospace',
      color: AppColors.heading,
      height: 1.6,
    );
    const lineNumStyle = TextStyle(
      fontSize: 13,
      fontFamily: 'monospace',
      color: AppColors.muted,
      height: 1.6,
    );

    if (editing) {
      return Container(
        color: const Color(0xFFFAFAFA),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Line numbers gutter
            Container(
              width: lineNumWidth,
              color: const Color(0xFFF0F0F0),
              child: ValueListenableBuilder<TextEditingValue>(
                valueListenable: _textController!,
                builder: (_, value, __) {
                  final count = '\n'.allMatches(value.text).length + 1;
                  return SingleChildScrollView(
                    controller: _editorScrollController,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: const EdgeInsets.only(top: 12, bottom: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: List.generate(count, (i) => SizedBox(
                        height: 13 * 1.6,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Text('${i + 1}', style: lineNumStyle, textAlign: TextAlign.right),
                        ),
                      )),
                    ),
                  );
                },
              ),
            ),
            // Divider
            Container(width: 1, color: AppColors.grey91),
            // Editor
            Expanded(
              child: NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  if (notification is ScrollUpdateNotification) {
                    _editorScrollController.jumpTo(
                      notification.metrics.pixels.clamp(0, _editorScrollController.position.maxScrollExtent),
                    );
                  }
                  return false;
                },
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: TextField(
                    controller: _textController,
                    maxLines: null,
                    keyboardType: TextInputType.multiline,
                    style: textStyle,
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      filled: false,
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    } else {
      // Read-only view with line numbers
      return Container(
        color: const Color(0xFFFAFAFA),
        child: SingleChildScrollView(
          padding: EdgeInsets.zero,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Line numbers
              Container(
                width: lineNumWidth,
                color: const Color(0xFFF0F0F0),
                padding: const EdgeInsets.only(top: 12, bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: List.generate(lineCount, (i) => SizedBox(
                    height: 13 * 1.6,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Text('${i + 1}', style: lineNumStyle, textAlign: TextAlign.right),
                    ),
                  )),
                ),
              ),
              Container(width: 1, color: AppColors.grey91),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(
                    text,
                    style: textStyle,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.grey98,
      resizeToAvoidBottomInset: !(_isOfficeDoc || _isSpreadsheet || _isPresentation),
      appBar: AppBar(
        title: Text(
          widget.file.name,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          overflow: TextOverflow.ellipsis,
        ),
        backgroundColor: AppColors.white,
        foregroundColor: AppColors.heading,
        elevation: 0,
        actions: [
          // Unsaved changes indicator
          if (_isText && _hasUnsavedChanges)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Icon(Icons.circle, size: 8, color: AppColors.away),
            ),
          // Save button for text files
          if (_isText && _isEditing)
            _isSaving
                ? const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.green700),
                    ),
                  )
                : IconButton(
                    icon: const Icon(Icons.save, color: AppColors.green700),
                    tooltip: 'Save',
                    onPressed: _hasUnsavedChanges ? _saveFile : null,
                  ),
          // Edit toggle for text files
          if (_isText && _bytes != null)
            IconButton(
              icon: Icon(
                _isEditing ? Icons.visibility : Icons.edit,
                color: _isEditing ? AppColors.green800 : AppColors.azure47,
              ),
              tooltip: _isEditing ? 'Read-only' : 'Edit',
              onPressed: () {
                setState(() {
                  _isEditing = !_isEditing;
                  if (_isEditing && _textController == null) {
                    final text = String.fromCharCodes(_bytes!);
                    _originalText = text;
                    _textController = TextEditingController(text: text);
                    _textController!.addListener(() {
                      final changed = _textController!.text != _originalText;
                      if (changed != _hasUnsavedChanges) {
                        setState(() => _hasUnsavedChanges = changed);
                      }
                    });
                  }
                });
              },
            ),
          // Download button
          IconButton(
            icon: const Icon(Icons.download, color: AppColors.azure47),
            onPressed: () => _downloadCurrentFile(),
          ),
          // Activity
          if (widget.file.fileId != null && widget.file.fileId!.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.history, color: AppColors.azure47),
              tooltip: 'Activity',
              onPressed: () => _showFileActivity(),
            ),
          // Share / open in browser
          IconButton(
            icon: const Icon(Icons.open_in_browser, color: AppColors.azure47),
            onPressed: () => _openInBrowser(),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: AppColors.green700),
                  SizedBox(height: 16),
                  Text('Loading file...', style: TextStyle(color: AppColors.body)),
                ],
              ),
            )
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline, size: 48, color: AppColors.filePdf),
                      const SizedBox(height: 16),
                      Text('Failed to load file', style: const TextStyle(color: AppColors.heading, fontSize: 16)),
                      const SizedBox(height: 8),
                      Text(_error!, style: const TextStyle(color: AppColors.body, fontSize: 13)),
                      const SizedBox(height: 16),
                      ElevatedButton(onPressed: _loadFile, child: const Text('Retry')),
                    ],
                  ),
                )
              : _buildPreview(),
    );
  }

  Widget _buildPreview() {
    if (_isPdf && _bytes != null) {
      return SfPdfViewer.memory(_bytes!);
    }

    if (_isImage && _bytes != null) {
      return InteractiveViewer(
        minScale: 0.5,
        maxScale: 5.0,
        child: Center(
          child: Image.memory(
            _bytes!,
            fit: BoxFit.contain,
          ),
        ),
      );
    }

    // Audio player
    if (_isAudio && _bytes != null) {
      return Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 400),
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  color: AppColors.greenActiveBg,
                  borderRadius: BorderRadius.circular(60),
                ),
                child: const Icon(Icons.music_note, size: 56, color: AppColors.green800),
              ),
              const SizedBox(height: 24),
              Text(widget.file.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.heading), textAlign: TextAlign.center),
              Text(widget.file.sizeFormatted, style: const TextStyle(fontSize: 13, color: AppColors.muted)),
              const SizedBox(height: 24),
              // Progress bar
              SliderTheme(
                data: SliderThemeData(
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                  trackHeight: 4,
                  activeTrackColor: AppColors.green700,
                  inactiveTrackColor: AppColors.grey91,
                  thumbColor: AppColors.green800,
                ),
                child: Slider(
                  value: _audioDuration.inMilliseconds > 0
                      ? _audioPosition.inMilliseconds / _audioDuration.inMilliseconds
                      : 0,
                  onChanged: (v) {
                    final pos = Duration(milliseconds: (v * _audioDuration.inMilliseconds).round());
                    _audioPlayer?.seek(pos);
                  },
                ),
              ),
              // Time labels
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(_formatDuration(_audioPosition), style: const TextStyle(fontSize: 12, color: AppColors.muted)),
                    Text(_formatDuration(_audioDuration), style: const TextStyle(fontSize: 12, color: AppColors.muted)),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // Controls
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    icon: const Icon(Icons.replay_10),
                    color: AppColors.azure47,
                    onPressed: () {
                      final newPos = _audioPosition - const Duration(seconds: 10);
                      _audioPlayer?.seek(newPos < Duration.zero ? Duration.zero : newPos);
                    },
                  ),
                  const SizedBox(width: 16),
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: AppColors.green800,
                      borderRadius: BorderRadius.circular(32),
                    ),
                    child: IconButton(
                      icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow, size: 32),
                      color: AppColors.white,
                      onPressed: () {
                        if (_isPlaying) {
                          _audioPlayer?.pause();
                        } else {
                          _audioPlayer?.resume();
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 16),
                  IconButton(
                    icon: const Icon(Icons.forward_10),
                    color: AppColors.azure47,
                    onPressed: () {
                      final newPos = _audioPosition + const Duration(seconds: 10);
                      _audioPlayer?.seek(newPos > _audioDuration ? _audioDuration : newPos);
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    // Spreadsheets (XLSX/XLS/ODS) — open via Nextcloud Office Online
    if (_isSpreadsheet) {
      return _buildNextcloudWebViewer();
    }

    // DrawIO — render in webview using draw.io viewer
    if (_isDrawio && _bytes != null) {
      return _buildDrawioView();
    }

    // Presentations (PPTX) — open via Nextcloud Office Online
    if (_isPresentation) {
      return _buildNextcloudWebViewer();
    }

    // Office docs (DOCX, DOC, etc.) — open via Nextcloud Office Online
    if (_isOfficeDoc) {
      return _buildNextcloudWebViewer();
    }

    if (_isText && _bytes != null) {
      if (_isEditing) {
        // Initialize controller if not done yet
        if (_textController == null) {
          final text = String.fromCharCodes(_bytes!);
          _originalText = text;
          _textController = TextEditingController(text: text);
          _textController!.addListener(() {
            final changed = _textController!.text != _originalText;
            if (changed != _hasUnsavedChanges) {
              setState(() => _hasUnsavedChanges = changed);
            }
          });
        }
        return _buildCodeEditor(editing: true);
      } else {
        return _buildCodeEditor(editing: false);
      }
    }

    // Unsupported file type (including office docs — webview approach is unreliable)
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.insert_drive_file, size: 64, color: AppColors.muted),
          const SizedBox(height: 16),
          Text(
            widget.file.name,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.heading),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            '${widget.file.extension.toUpperCase()} file  -  ${widget.file.sizeFormatted}',
            style: const TextStyle(fontSize: 14, color: AppColors.body),
          ),
          const SizedBox(height: 24),
          const Text(
            'Preview not available for this file type.',
            style: TextStyle(color: AppColors.muted, fontSize: 13),
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _openInBrowser,
            icon: const Icon(Icons.open_in_browser, size: 18),
            label: const Text('Open in Browser'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.green800,
              foregroundColor: AppColors.white,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showFileActivity() async {
    final auth = context.read<AuthService>();
    final webdav = WebDavService(auth);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        return FutureBuilder<List<Map<String, dynamic>>>(
          future: webdav.getFileActivity(widget.file.fileId!),
          builder: (ctx, snapshot) {
            return Container(
              height: MediaQuery.of(ctx).size.height * 0.6,
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.history, color: AppColors.green800, size: 20),
                      const SizedBox(width: 8),
                      Text('Activity — ${widget.file.name}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.heading)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Divider(),
                  Expanded(
                    child: snapshot.connectionState == ConnectionState.waiting
                        ? const Center(child: CircularProgressIndicator(color: AppColors.green700))
                        : snapshot.hasError || (snapshot.data?.isEmpty ?? true)
                            ? const Center(child: Text('No activity found', style: TextStyle(color: AppColors.muted)))
                            : ListView.builder(
                                itemCount: snapshot.data!.length,
                                itemBuilder: (_, i) {
                                  final a = snapshot.data![i];
                                  final subject = a['subject'] as String? ?? '';
                                  final user = a['user'] as String? ?? '';
                                  final dateStr = a['datetime'] as String? ?? '';
                                  DateTime? date;
                                  try { date = DateTime.parse(dateStr); } catch (_) {}
                                  final timeAgo = date != null ? _timeAgo(date) : '';

                                  return Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 8),
                                    child: Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        CircleAvatar(
                                          radius: 16,
                                          backgroundColor: AppColors.green700,
                                          child: Text(user.isNotEmpty ? user[0].toUpperCase() : '?', style: const TextStyle(color: AppColors.white, fontSize: 12)),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(subject, style: const TextStyle(fontSize: 13, color: AppColors.heading)),
                                              Text('$user • $timeAgo', style: const TextStyle(fontSize: 11, color: AppColors.muted)),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  String _timeAgo(DateTime date) {
    final diff = DateTime.now().difference(date);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${date.day}/${date.month}/${date.year}';
  }

  Future<void> _downloadCurrentFile() async {
    Uint8List bytes;
    if (_bytes != null) {
      bytes = _bytes!;
    } else {
      // File not loaded (office docs) — download from server
      try {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Downloading...'), backgroundColor: AppColors.green700, duration: Duration(seconds: 1)),
          );
        }
        final auth = context.read<AuthService>();
        final webdav = WebDavService(auth);
        bytes = await webdav.downloadFile(widget.file.path);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Download failed: $e'), backgroundColor: AppColors.filePdf),
          );
        }
        return;
      }
    }

    try {
      final isMobile = Platform.isIOS || Platform.isAndroid;
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save ${widget.file.name}',
        fileName: widget.file.name,
        bytes: isMobile ? bytes : null,
      );
      if (savePath == null) return;
      if (!isMobile) {
        await File(savePath).writeAsBytes(bytes);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${widget.file.name} saved'), backgroundColor: AppColors.green700),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e'), backgroundColor: AppColors.filePdf),
        );
      }
    }
  }

  Future<void> _showDownloadInfo() async {
    if (_bytes == null) return;
    try {
      final isMobile = Platform.isIOS || Platform.isAndroid;
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save ${widget.file.name}',
        fileName: widget.file.name,
        bytes: isMobile ? _bytes : null,
      );
      if (savePath == null) return;
      // On desktop, write bytes manually
      if (!isMobile) {
        await File(savePath).writeAsBytes(_bytes!);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${widget.file.name} saved successfully'),
            backgroundColor: AppColors.green700,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Save failed: $e'),
            backgroundColor: AppColors.filePdf,
          ),
        );
      }
    }
  }

  Widget _buildSpreadsheetView() {
    try {
      final decoder = SpreadsheetDecoder.decodeBytes(_bytes!);
      final sheetNames = decoder.tables.keys.toList();

      return DefaultTabController(
        length: sheetNames.length,
        child: Column(
          children: [
            // Sheet tabs
            if (sheetNames.length > 1)
              Container(
                color: AppColors.white,
                child: TabBar(
                  isScrollable: true,
                  labelColor: AppColors.green800,
                  unselectedLabelColor: AppColors.body,
                  indicatorColor: AppColors.green800,
                  labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  tabs: sheetNames.map((n) => Tab(text: n)).toList(),
                ),
              ),
            Expanded(
              child: TabBarView(
                children: sheetNames.map((name) {
                  final table = decoder.tables[name]!;
                  if (table.rows.isEmpty) {
                    return const Center(child: Text('Empty sheet', style: TextStyle(color: AppColors.muted)));
                  }

                  // Determine max columns
                  int maxCols = 0;
                  for (final row in table.rows) {
                    if (row.length > maxCols) maxCols = row.length;
                  }

                  return Container(
                    color: AppColors.white,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.vertical,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Table(
                          border: TableBorder.all(color: AppColors.grey91, width: 1),
                          defaultColumnWidth: const IntrinsicColumnWidth(flex: 1),
                          children: [
                            // Header row (row 0) with column letters
                            TableRow(
                              decoration: const BoxDecoration(color: AppColors.grey96),
                              children: [
                                // Row number column header
                                Container(
                                  width: 40,
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                                  child: const Text('', style: TextStyle(fontSize: 11, color: AppColors.muted)),
                                ),
                                ...List.generate(maxCols, (col) => Container(
                                  constraints: const BoxConstraints(minWidth: 100),
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                                  child: Text(
                                    String.fromCharCode(65 + (col % 26)),
                                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.muted),
                                    textAlign: TextAlign.center,
                                  ),
                                )),
                              ],
                            ),
                            // Data rows
                            ...table.rows.asMap().entries.map((entry) {
                              final rowIdx = entry.key;
                              final row = entry.value;
                              final isHeader = rowIdx == 0;
                              return TableRow(
                                decoration: BoxDecoration(
                                  color: isHeader ? AppColors.grey96 : (rowIdx % 2 == 0 ? AppColors.white : AppColors.grey98),
                                ),
                                children: [
                                  // Row number
                                  Container(
                                    width: 40,
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                                    color: AppColors.grey96,
                                    child: Text(
                                      '${rowIdx + 1}',
                                      style: const TextStyle(fontSize: 11, color: AppColors.muted),
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                                  // Cell values
                                  ...List.generate(maxCols, (col) {
                                    final value = col < row.length ? '${row[col] ?? ''}' : '';
                                    return Container(
                                      constraints: const BoxConstraints(minWidth: 100),
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                      child: Text(
                                        value,
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: isHeader ? FontWeight.w600 : FontWeight.w400,
                                          color: isHeader ? AppColors.heading : AppColors.body,
                                        ),
                                      ),
                                    );
                                  }),
                                ],
                              );
                            }),
                          ],
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      );
    } catch (e) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.table_chart, size: 48, color: AppColors.muted),
            const SizedBox(height: 16),
            Text('Could not parse spreadsheet: $e', style: const TextStyle(color: AppColors.body, fontSize: 13), textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _openInBrowser,
              icon: const Icon(Icons.open_in_browser, size: 18),
              label: const Text('Open in Browser'),
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.green800, foregroundColor: AppColors.white),
            ),
          ],
        ),
      );
    }
  }

  Widget _buildOpenWithSystemViewer(IconData icon, Color color) {
    // Auto-open with system viewer on first load
    _openWithSystem();
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, size: 40, color: color),
          ),
          const SizedBox(height: 16),
          Text(widget.file.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.heading), textAlign: TextAlign.center),
          const SizedBox(height: 4),
          Text('${widget.file.extension.toUpperCase()}  -  ${widget.file.sizeFormatted}', style: const TextStyle(fontSize: 14, color: AppColors.body)),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _openWithSystem,
            icon: const Icon(Icons.open_in_new, size: 18),
            label: const Text('Open'),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.green800, foregroundColor: AppColors.white),
          ),
          const SizedBox(height: 8),
          const Text('Opening with system viewer...', style: TextStyle(fontSize: 12, color: AppColors.muted)),
        ],
      ),
    );
  }

  bool _hasOpenedWithSystem = false;
  Future<void> _openWithSystem() async {
    if (_bytes == null) return;
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/${widget.file.name}');
      await file.writeAsBytes(_bytes!);
      await OpenFilex.open(file.path);
      _hasOpenedWithSystem = true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open: $e')),
        );
      }
    }
  }

  Widget _buildNextcloudWebViewer() {
    final auth = context.read<AuthService>();
    final fileId = widget.file.fileId;
    if (fileId == null || fileId.isEmpty) {
      return Center(child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 48, color: AppColors.muted),
          const SizedBox(height: 16),
          const Text('Cannot open: no file ID', style: TextStyle(color: AppColors.body)),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _openInBrowser,
            icon: const Icon(Icons.open_in_browser, size: 18),
            label: const Text('Open in Browser'),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.green800, foregroundColor: AppColors.white),
          ),
        ],
      ));
    }

    final targetUrl = '${auth.serverUrl}/index.php/apps/files/files/$fileId?dir=/&openfile=true';
    final sessionUrl = '${auth.serverUrl}/remote.php/dav/files/${auth.userId}/';

    final hideJs = '''
      var s = document.createElement('style');
      s.textContent = '#header, header[role="banner"], .header { display: none !important; } .app-sidebar, #app-sidebar-vue, .app-sidebar-header { display: none !important; } .header-close, .icon-close, .action-item--single[aria-label="Close"], .menutoggle, .header-menu, .app-menu-main, .action-item, .files-controls .actions, .breadcrumb .action-item, button.action-item, .NotesFileAction, [class*="action-item"], .files-list__header-action, .button-vue--icon-only { display: none !important; }';
      document.head.appendChild(s);
      setTimeout(function() {
        var closeBtn = document.querySelector('.app-sidebar__close, .icon-close, [aria-label="Close sidebar"]');
        if (closeBtn) closeBtn.click();
      }, 1000);
    ''';

    // Android/Linux: use InAppWebView
    if (Platform.isAndroid || Platform.isLinux) {
      return _buildInAppWebViewer(auth, sessionUrl, targetUrl, hideJs);
    }

    // macOS / iOS — use webview_flutter
    final authedSessionUrl = Uri.parse(sessionUrl).replace(
      userInfo: '${Uri.encodeComponent(auth.username!)}:${Uri.encodeComponent(auth.appPassword!)}',
    );

    late final WebViewController controller;
    bool _sessionEstablished = false;
    bool _fileLoaded = false;
    final ValueNotifier<bool> _showWebView = ValueNotifier(false);

    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36')
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (url) {
          if (!_sessionEstablished) {
            _sessionEstablished = true;
            controller.loadRequest(Uri.parse(targetUrl));
            return;
          }
          // Disable pinch zoom on iOS
          if (Platform.isIOS) {
            controller.runJavaScript('''
              var meta = document.querySelector('meta[name="viewport"]');
              if (!meta) { meta = document.createElement("meta"); meta.name = "viewport"; document.head.appendChild(meta); }
              meta.content = "width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no";
            ''');
          }
          controller.runJavaScript(hideJs);
          if (!_fileLoaded) {
            _fileLoaded = true;
            _showWebView.value = true;
          }
        },
      ));

    controller.loadRequest(authedSessionUrl);

    return ValueListenableBuilder<bool>(
      valueListenable: _showWebView,
      builder: (context, show, _) {
        return Stack(
          children: [
            WebViewWidget(controller: controller),
            if (!show)
              Container(
                color: AppColors.white,
                child: const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: AppColors.green700),
                      SizedBox(height: 16),
                      Text('Opening document...', style: TextStyle(color: AppColors.body, fontSize: 14)),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildInAppWebViewer(AuthService auth, String sessionUrl, String targetUrl, String hideJs) {
    bool sessionDone = false;
    bool hideDone = false;
    return inapp.InAppWebView(
      initialUrlRequest: inapp.URLRequest(
        url: inapp.WebUri(sessionUrl),
        headers: {'Authorization': auth.basicAuth},
      ),
      initialSettings: inapp.InAppWebViewSettings(
        javaScriptEnabled: true,
        javaScriptCanOpenWindowsAutomatically: true,
      ),
      onLoadStop: (controller, url) async {
        if (!sessionDone) {
          sessionDone = true;
          await controller.loadUrl(urlRequest: inapp.URLRequest(url: inapp.WebUri(targetUrl)));
          return;
        }
        if (!hideDone) {
          hideDone = true;
          await controller.evaluateJavascript(source: hideJs);
        }
      },
      onReceivedHttpAuthRequest: (controller, challenge) async {
        return inapp.HttpAuthResponse(
          username: auth.username ?? '',
          password: auth.appPassword ?? '',
          action: inapp.HttpAuthResponseAction.PROCEED,
        );
      },
      onReceivedServerTrustAuthRequest: (controller, challenge) async {
        return inapp.ServerTrustAuthResponse(
          action: inapp.ServerTrustAuthResponseAction.PROCEED,
        );
      },
    );
  }

  Widget _buildDrawioView() {
    // Draw.io files are XML — render using the draw.io embed viewer
    final xmlContent = String.fromCharCodes(_bytes!);
    final encodedXml = Uri.encodeComponent(xmlContent);
    // Use draw.io's viewer to render the diagram
    final viewerUrl = 'https://viewer.diagrams.net/?highlight=0000ff&nav=1&title=${Uri.encodeComponent(widget.file.name)}#R$encodedXml';

    late final WebViewController controller;
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..loadRequest(Uri.parse(viewerUrl));

    return WebViewWidget(controller: controller);
  }

  Future<void> _openInBrowser() async {
    final auth = context.read<AuthService>();
    if (widget.file.fileId != null && widget.file.fileId!.isNotEmpty) {
      final url = Uri.parse('${auth.serverUrl}/index.php/f/${widget.file.fileId}');
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
  }
}
