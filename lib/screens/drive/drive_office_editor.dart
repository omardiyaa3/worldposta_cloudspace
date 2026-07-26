// drive_office_editor.dart — edit Office files (docx/xlsx/pptx) in Collabora.
//
// Mirrors the Drive web app: POST /files/{id}/wopi-edit-url returns a single,
// self-contained Collabora URL (WOPISrc + access_token embedded), which we load
// in a webview just as the web app drops it into an <iframe>. The embedded token
// authorises the WOPI protocol calls, so no cookies are needed. Falls back to
// opening the URL in the system browser (the URL is portable).

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config/theme.dart';
import '../../models/drive_file.dart';
import '../../services/drive/drive_account_manager.dart';
import '../../services/drive/drive_client.dart';

class DriveOfficeEditor extends StatefulWidget {
  final DriveFile file;
  const DriveOfficeEditor({super.key, required this.file});

  @override
  State<DriveOfficeEditor> createState() => _DriveOfficeEditorState();
}

class _DriveOfficeEditorState extends State<DriveOfficeEditor> {
  String? _url;
  String? _error;
  bool _loadingUrl = true;
  bool _pageLoading = true;
  bool _opened = false; // Windows: launched in the external browser

  // Windows webviews (WebView2) are unreliable — open Collabora in the real
  // browser. The WOPI URL is self-contained (token embedded), so it just works.
  bool get _useBrowser => Platform.isWindows;

  @override
  void initState() {
    super.initState();
    _fetchUrl();
  }

  Future<void> _fetchUrl() async {
    setState(() { _loadingUrl = true; _error = null; });
    try {
      final api = context.read<DriveAccountManager>().activeApi!;
      final res = await api.wopiEditUrl(widget.file.id);
      if (!mounted) return;
      setState(() { _url = res.url; _loadingUrl = false; });
      if (_useBrowser) await _openInBrowser();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingUrl = false;
          _error = e is DriveException
              ? (e.code == 'validation_error' || e.message.contains('not supported')
                  ? 'This file type can\'t be edited in Office Online.'
                  : e.message)
              : e.toString();
        });
      }
    }
  }

  Future<void> _openInBrowser() async {
    if (_url == null) return;
    try {
      await launchUrl(Uri.parse(_url!), mode: LaunchMode.externalApplication);
      if (mounted) setState(() => _opened = true);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.grey98,
      appBar: AppBar(
        title: Text(widget.file.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
        backgroundColor: AppColors.white,
        foregroundColor: AppColors.heading,
        elevation: 0,
        actions: [
          if (_url != null)
            IconButton(icon: const Icon(Icons.open_in_browser, color: AppColors.azure47), tooltip: 'Open in browser', onPressed: _openInBrowser),
        ],
      ),
      body: _loadingUrl
          ? const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              CircularProgressIndicator(color: AppColors.green700),
              SizedBox(height: 16),
              Text('Opening in Office Online…', style: TextStyle(color: AppColors.body)),
            ]))
          : _error != null
              ? _errorView()
              : _useBrowser
              ? _browserView()
              : Stack(children: [
                  inapp.InAppWebView(
                    initialUrlRequest: inapp.URLRequest(url: inapp.WebUri(_url!)),
                    initialSettings: inapp.InAppWebViewSettings(
                      javaScriptEnabled: true,
                      javaScriptCanOpenWindowsAutomatically: true,
                      transparentBackground: true,
                    ),
                    onLoadStop: (controller, url) { if (mounted) setState(() => _pageLoading = false); },
                    onReceivedServerTrustAuthRequest: (controller, challenge) async =>
                        inapp.ServerTrustAuthResponse(action: inapp.ServerTrustAuthResponseAction.PROCEED),
                  ),
                  if (_pageLoading)
                    Container(
                      color: AppColors.white,
                      child: const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                        CircularProgressIndicator(color: AppColors.green700),
                        SizedBox(height: 16),
                        Text('Loading editor…', style: TextStyle(color: AppColors.body, fontSize: 14)),
                      ])),
                    ),
                ]),
    );
  }

  Widget _browserView() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.open_in_browser, size: 56, color: AppColors.green700),
            const SizedBox(height: 16),
            Text(
              _opened
                  ? '“${widget.file.name}” is open in your browser.\nEdits save back to your Drive automatically.'
                  : 'Ready to open in your browser.',
              style: const TextStyle(color: AppColors.body, fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: _openInBrowser,
              icon: const Icon(Icons.open_in_browser, size: 18),
              label: Text(_opened ? 'Re-open in browser' : 'Open in browser'),
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.green800, foregroundColor: AppColors.white),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('Done', style: TextStyle(color: AppColors.muted)),
            ),
          ]),
        ),
      );

  Widget _errorView() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.edit_note, size: 56, color: AppColors.muted),
            const SizedBox(height: 16),
            Text(_error!, style: const TextStyle(color: AppColors.body, fontSize: 14), textAlign: TextAlign.center),
            const SizedBox(height: 20),
            if (_url != null)
              ElevatedButton.icon(
                onPressed: _openInBrowser,
                icon: const Icon(Icons.open_in_browser, size: 18),
                label: const Text('Open in browser'),
                style: ElevatedButton.styleFrom(backgroundColor: AppColors.green800, foregroundColor: AppColors.white),
              )
            else
              ElevatedButton.icon(
                onPressed: _fetchUrl,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Retry'),
                style: ElevatedButton.styleFrom(backgroundColor: AppColors.green800, foregroundColor: AppColors.white),
              ),
          ]),
        ),
      );
}
