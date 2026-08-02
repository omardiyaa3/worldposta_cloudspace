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

  // The office backend is Microsoft Office Online Server (WOPI). Its mobile chrome
  // shows a back/close button (`closebutton`, inside a nested same-origin iframe)
  // that's redundant with — and disconnected from — the app's AppBar back button.
  // Rather than hide it (Office re-renders it), we intercept its tap in the capture
  // phase (before Office's own handler), across the page and its frames, and pop
  // the Flutter editor route via the `officeBack` handler. Listeners are attached
  // at the document level so they survive Office re-rendering the button.
  // The office backend is Microsoft Office Online Server (WOPI). Its mobile back
  // button (`div#toolbar-mobile-back`, inside a nested same-origin iframe) is
  // redundant with the app's AppBar back and, when tapped in view mode, doesn't
  // return to the app. So we intercept its tap and pop the editor route.
  //
  // CRUCIAL: in EDIT mode the SAME button becomes Save (it then carries the class
  // `editmode-on`). We must NOT intercept it there, or edits are lost. So we pop
  // ONLY when `editmode-on` is absent (view mode = pure back); in edit mode we let
  // Office handle the tap so it saves. Listeners are attached at the document
  // level (and in nested frames) so they survive Office re-rendering the toolbar.
  static const String _officeBackJs = r'''
(function(){
  if (window.__csOfficeBack) return; window.__csOfficeBack = true;
  function bridge(){ try{ return (window.top&&window.top.flutter_inappwebview)||window.flutter_inappwebview; }catch(e){ return window.flutter_inappwebview; } }
  function findBack(el){ var n=0; while(el&&n<6){ if(el.id==='toolbar-mobile-back') return el; el=el.parentElement; n++; } return null; }
  var last=0;
  function onTap(e){
    var btn=findBack(e.target);
    if(!btn) return;
    if(/\beditmode-on\b/.test(btn.getAttribute('class')||'')) return; // edit mode → Save; let it through
    try{ e.preventDefault(); e.stopPropagation(); }catch(_){}
    var now=Date.now(); if(now-last<700) return; last=now;
    try{ bridge().callHandler('officeBack'); }catch(_){}
  }
  function attach(){
    var ds=[document];
    (function rec(root){ try{ var f=root.querySelectorAll('iframe'); for(var i=0;i<f.length;i++){ try{ if(f[i].contentDocument){ ds.push(f[i].contentDocument); rec(f[i].contentDocument);} }catch(e){} } }catch(e){} })(document);
    ds.forEach(function(d){ try{ if(!d.__csBack){ d.__csBack=true; ['pointerdown','click','touchend'].forEach(function(ev){ d.addEventListener(ev, onTap, true); }); } }catch(e){} });
  }
  attach(); setInterval(attach, 1000);
})();
''';

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
          _error = (e is DriveException && (e.code == 'validation_error' || e.message.contains('not supported')))
              ? 'This file type can\'t be edited in Office Online.'
              : friendlyError(e);
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

  // On iOS, once the office doc has rendered its own back button we hide the app's
  // redundant one — leaving a single back button. Kept while loading / on error
  // (the doc's button isn't there yet) and on Windows (browser mode) / macOS
  // (desktop Office has no mobile back button), where the app's back is the exit.
  bool get _showAppBack {
    if (!Platform.isIOS || _useBrowser) return true;
    return _loadingUrl || _error != null || _pageLoading;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.grey98,
      appBar: AppBar(
        automaticallyImplyLeading: _showAppBack,
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
                    onWebViewCreated: (controller) {
                      controller.addJavaScriptHandler(
                        handlerName: 'officeBack',
                        callback: (args) {
                          if (mounted) Navigator.of(context).maybePop();
                          return null;
                        },
                      );
                    },
                    onLoadStop: (controller, url) async {
                      await controller.evaluateJavascript(source: _officeBackJs);
                      if (mounted) setState(() => _pageLoading = false);
                    },
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
