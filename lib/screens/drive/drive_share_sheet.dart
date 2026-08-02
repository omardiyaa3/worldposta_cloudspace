// drive_share_sheet.dart — share a file/folder with people or via a public link.
//
// People:  GET /users/search (autocomplete) → POST /permissions (named roles
//          viewer/commenter/editor/manager), listed with inherited badges,
//          revoked via DELETE /permissions/{id}.
// Links:   POST /shares (optional password + expiry) → copyable URL, listed and
//          revoked via DELETE /shares/{id}.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../config/theme.dart';
import '../../models/drive_file.dart';
import '../../services/drive/drive_account_manager.dart';
import '../../services/drive/drive_api.dart';
import '../../services/drive/drive_client.dart';

Future<void> showDriveShareSheet(BuildContext context, DriveFile file) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true, // reliable drag-to-dismiss even when it fills the screen
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (_) => DriveShareSheet(file: file),
  );
}

class DriveShareSheet extends StatefulWidget {
  final DriveFile file;
  const DriveShareSheet({super.key, required this.file});

  @override
  State<DriveShareSheet> createState() => _DriveShareSheetState();
}

class _DriveShareSheetState extends State<DriveShareSheet> {
  DriveApi get _api => context.read<DriveAccountManager>().activeApi!;

  final _searchCtrl = TextEditingController();
  DriveRole _role = DriveRole.viewer;

  List<DriveUser> _allUsers = []; // tenant directory (empty-query search returns all)
  List<DrivePermission> _perms = [];
  List<DriveShare> _links = [];
  bool _loading = true;
  bool _working = false;
  String? _msg;
  bool _msgErr = false;

  // Public link options.
  DriveRole _linkPermission = DriveRole.viewer; // viewer | commenter | editor
  bool _linkAllowDownload = true;
  final _passwordCtrl = TextEditingController();
  final _cardScroll = ScrollController();   // outer card scroll (grabbable, in a side gutter)
  final _peopleScroll = ScrollController(); // inner people-list scroll
  DateTime? _expiry;

  String? get _currentUserId => context.read<DriveAccountManager>().activeAccount?.userId;

  @override
  void initState() {
    super.initState();
    _load();
    _searchCtrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _passwordCtrl.dispose();
    _cardScroll.dispose();
    _peopleScroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await Future.wait([
        _api.listPermissions(widget.file.id),
        _api.listShares(),
        _api.searchUsers('', limit: 200), // all tenant users
      ]);
      if (mounted) {
        setState(() {
          _perms = r[0] as List<DrivePermission>;
          _links = (r[1] as List<DriveShare>).where((s) => s.resourceId == widget.file.id).toList();
          _allUsers = r[2] as List<DriveUser>;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _loading = false; _flash(_friendly(e), err: true); });
    }
  }

  /// Directory to show: everyone in the tenant except me and anyone already
  /// granted, filtered by the search text.
  List<DriveUser> get _pickable {
    final q = _searchCtrl.text.trim().toLowerCase();
    final granted = _perms.map((p) => p.subjectId).toSet();
    return _allUsers.where((u) {
      if (u.id == _currentUserId || granted.contains(u.id)) return false;
      if (q.isEmpty) return true;
      return u.displayName.toLowerCase().contains(q) || u.email.toLowerCase().contains(q);
    }).toList();
  }

  String _friendly(Object e) => friendlyError(e);
  void _flash(String m, {bool err = false}) => setState(() { _msg = m; _msgErr = err; });

  Future<void> _grantTo(DriveUser u) async {
    setState(() => _working = true);
    try {
      await _api.grantPermission(resourceId: widget.file.id, subjectType: 'user', subjectId: u.id, role: _role);
      _searchCtrl.clear();
      await _load();
      _flash('Shared with ${u.displayName} as ${_roleLabel(_role)}');
    } catch (e) {
      _flash('Share failed: ${_friendly(e)}', err: true);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  /// Change a person's role — the backend upserts, so re-granting with the new
  /// role updates the existing grant.
  Future<void> _changeRole(DrivePermission p, DriveRole role) async {
    if (role == p.role) return;
    setState(() => _working = true);
    try {
      await _api.grantPermission(resourceId: widget.file.id, subjectType: p.subjectType, subjectId: p.subjectId, role: role);
      await _load();
      _flash('Updated to ${_roleLabel(role)}');
    } catch (e) {
      _flash('Update failed: ${_friendly(e)}', err: true);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _changeLinkPermission(DriveShare s, DriveRole role) async {
    if (role.wire == s.permission) return;
    try {
      await _api.updateShare(s.id, permission: role.wire);
      await _load();
      _flash('Link set to ${_roleLabel(role)}');
    } catch (e) {
      _flash('Update failed: ${_friendly(e)}', err: true);
    }
  }

  Future<void> _revoke(DrivePermission p) async {
    try {
      await _api.revokePermission(p.id);
      setState(() => _perms.removeWhere((x) => x.id == p.id));
      _flash('Access removed');
    } catch (e) {
      _flash('Failed: ${_friendly(e)}', err: true);
    }
  }

  Future<void> _createLink() async {
    setState(() => _working = true);
    try {
      final share = await _api.createShare(
        widget.file.id,
        password: _passwordCtrl.text.trim().isEmpty ? null : _passwordCtrl.text.trim(),
        expiresAt: _expiry,
        allowDownload: _linkAllowDownload,
        permission: _linkPermission.wire, // viewer | commenter | editor
      );
      _passwordCtrl.clear();
      setState(() => _expiry = null);
      await Clipboard.setData(ClipboardData(text: share.url));
      await _load();
      _flash('Public link created and copied');
    } catch (e) {
      _flash('Link failed: ${_friendly(e)}', err: true);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _revokeLink(DriveShare s) async {
    try {
      await _api.deleteShare(s.id);
      setState(() => _links.removeWhere((x) => x.id == s.id));
      _flash('Link revoked');
    } catch (e) {
      _flash('Failed: ${_friendly(e)}', err: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 20, 12, MediaQuery.of(context).viewInsets.bottom + 20),
      // Always-visible card scrollbar living in a right-hand gutter, kept clear of
      // the content, so it's easy to grab and scroll the whole card even when the
      // pointer is over the (separately scrollable) people list.
      child: Scrollbar(
        controller: _cardScroll,
        thumbVisibility: true,
        child: SingleChildScrollView(
        controller: _cardScroll,
        padding: const EdgeInsets.only(right: 12),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.share, color: AppColors.green800, size: 22),
            const SizedBox(width: 10),
            Expanded(child: Text('Share "${widget.file.name}"', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.heading), overflow: TextOverflow.ellipsis)),
          ]),
          const SizedBox(height: 16),

          if (_msg != null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: (_msgErr ? AppColors.filePdf : AppColors.green700).withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
              child: Row(children: [
                Icon(_msgErr ? Icons.error_outline : Icons.check_circle, size: 16, color: _msgErr ? AppColors.filePdf : AppColors.green700),
                const SizedBox(width: 8),
                Expanded(child: Text(_msg!, style: TextStyle(fontSize: 12, color: _msgErr ? AppColors.filePdf : AppColors.green800))),
              ]),
            ),

          if (_loading)
            const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator(color: AppColors.green700)))
          else ...[
            // People — pick from the tenant directory.
            Row(children: [
              const Expanded(child: Text('Add people in your organization', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.heading))),
              const Text('as ', style: TextStyle(fontSize: 12, color: AppColors.body)),
              DropdownButton<DriveRole>(
                value: _role,
                isDense: true,
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: DriveRole.viewer, child: Text('Viewer')),
                  DropdownMenuItem(value: DriveRole.commenter, child: Text('Commenter')),
                  DropdownMenuItem(value: DriveRole.editor, child: Text('Editor')),
                  DropdownMenuItem(value: DriveRole.manager, child: Text('Manager')),
                ],
                onChanged: (v) => setState(() => _role = v ?? DriveRole.viewer),
              ),
            ]),
            const SizedBox(height: 8),
            TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: 'Search people…',
                prefixIcon: const Icon(Icons.person_search, size: 20, color: AppColors.muted),
                filled: true,
                fillColor: AppColors.grey96,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            ),
            const SizedBox(height: 6),
            Container(
              constraints: const BoxConstraints(maxHeight: 180),
              decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppColors.grey91)),
              child: _pickable.isEmpty
                  ? const Padding(padding: EdgeInsets.all(16), child: Text('No people to add', style: TextStyle(fontSize: 12, color: AppColors.muted)))
                  : Scrollbar(controller: _peopleScroll, thumbVisibility: true, child: ListView(controller: _peopleScroll, shrinkWrap: true, children: _pickable.map((u) => ListTile(
                        dense: true,
                        leading: CircleAvatar(radius: 14, backgroundColor: AppColors.green700, child: Text(u.displayName.isNotEmpty ? u.displayName[0].toUpperCase() : '?', style: const TextStyle(color: AppColors.white, fontSize: 12))),
                        title: Text(u.displayName, style: const TextStyle(fontSize: 13)),
                        subtitle: Text(u.email, style: const TextStyle(fontSize: 11, color: AppColors.muted)),
                        trailing: _working
                            ? null
                            : TextButton.icon(
                                onPressed: () => _grantTo(u),
                                icon: const Icon(Icons.add, size: 16, color: AppColors.green700),
                                label: const Text('Add', style: TextStyle(color: AppColors.green700, fontSize: 13)),
                              ),
                        onTap: _working ? null : () => _grantTo(u),
                      )).toList())),
            ),

            if (_perms.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('People with access', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.heading)),
              ..._perms.map((p) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(p.subjectType == 'group' ? Icons.group_outlined : Icons.person_outline, size: 20, color: AppColors.green800),
                    title: Text(p.subjectName ?? p.subjectEmail ?? p.subjectId, style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis),
                    subtitle: p.isInherited ? const Text('inherited', style: TextStyle(fontSize: 11, color: AppColors.muted)) : null,
                    trailing: p.isInherited
                        ? const Icon(Icons.lock_outline, size: 16, color: AppColors.muted)
                        : PopupMenuButton<String>(
                            enabled: !_working,
                            onSelected: (v) => v == 'remove' ? _revoke(p) : _changeRole(p, DriveRoleX.fromWire(v)!),
                            itemBuilder: (_) => [
                              for (final r in [DriveRole.viewer, DriveRole.commenter, DriveRole.editor, DriveRole.manager])
                                CheckedPopupMenuItem(value: r.wire, checked: p.role == r, child: Text(_roleLabel(r))),
                              const PopupMenuDivider(),
                              const PopupMenuItem(value: 'remove', child: Row(children: [Icon(Icons.person_remove, size: 16, color: AppColors.filePdf), SizedBox(width: 8), Text('Remove', style: TextStyle(color: AppColors.filePdf))])),
                            ],
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Text(_roleLabel(p.role), style: const TextStyle(fontSize: 12, color: AppColors.green700, fontWeight: FontWeight.w500)),
                              const Icon(Icons.arrow_drop_down, size: 18, color: AppColors.green700),
                            ]),
                          ),
                  )),
            ],

            const SizedBox(height: 20),
            const Divider(),
            const SizedBox(height: 4),

            // Public link
            Row(children: [
              const Expanded(child: Text('Public link', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.heading))),
              const Text('Anyone can ', style: TextStyle(fontSize: 12, color: AppColors.body)),
              DropdownButton<DriveRole>(
                value: _linkPermission,
                isDense: true,
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: DriveRole.viewer, child: Text('View')),
                  DropdownMenuItem(value: DriveRole.commenter, child: Text('Comment')),
                  DropdownMenuItem(value: DriveRole.editor, child: Text('Edit')),
                ],
                onChanged: (v) => setState(() => _linkPermission = v ?? DriveRole.viewer),
              ),
            ]),
            const SizedBox(height: 8),
            TextField(
              controller: _passwordCtrl,
              obscureText: true,
              decoration: InputDecoration(
                hintText: 'Password (optional)',
                prefixIcon: const Icon(Icons.lock_outline, size: 18, color: AppColors.muted),
                filled: true,
                fillColor: AppColors.grey96,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            ),
            const SizedBox(height: 8),
            Row(children: [
              InkWell(
                onTap: () async {
                  final d = await showDatePicker(context: context, initialDate: _expiry ?? DateTime.now().add(const Duration(days: 7)), firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 365)));
                  if (d != null) setState(() => _expiry = d);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(color: AppColors.grey96, borderRadius: BorderRadius.circular(8)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.calendar_today, size: 16, color: AppColors.muted),
                    const SizedBox(width: 8),
                    Text(_expiry != null ? 'Expires ${DateFormat('MMM d, y').format(_expiry!)}' : 'No expiry', style: const TextStyle(fontSize: 13, color: AppColors.heading)),
                    if (_expiry != null) ...[
                      const SizedBox(width: 6),
                      GestureDetector(onTap: () => setState(() => _expiry = null), child: const Icon(Icons.close, size: 14, color: AppColors.muted)),
                    ],
                  ]),
                ),
              ),
              const Spacer(),
              Row(children: [
                Checkbox(value: _linkAllowDownload, activeColor: AppColors.green800, onChanged: (v) => setState(() => _linkAllowDownload = v ?? true)),
                const Text('Allow download', style: TextStyle(fontSize: 12, color: AppColors.body)),
              ]),
            ]),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _working ? null : _createLink,
                icon: const Icon(Icons.link, size: 18),
                label: const Text('Create Public Link'),
                style: OutlinedButton.styleFrom(foregroundColor: AppColors.green700),
              ),
            ),
            ..._links.map((s) => ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.link, size: 20, color: AppColors.green800),
                  title: Text(s.url, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis),
                  subtitle: Text('${s.hasPassword ? 'Password · ' : ''}${s.expiresAt != null ? 'Expires ${DateFormat('MMM d').format(s.expiresAt!)}' : 'No expiry'}', style: const TextStyle(fontSize: 11, color: AppColors.muted)),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    // Change link permission (View / Comment / Edit).
                    PopupMenuButton<DriveRole>(
                      tooltip: 'Permission',
                      onSelected: (r) => _changeLinkPermission(s, r),
                      itemBuilder: (_) => [
                        for (final r in [DriveRole.viewer, DriveRole.commenter, DriveRole.editor])
                          CheckedPopupMenuItem(value: r, checked: s.permission == r.wire, child: Text(_linkVerb(r))),
                      ],
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(_linkVerb(DriveRoleX.fromWire(s.permission) ?? DriveRole.viewer), style: const TextStyle(fontSize: 12, color: AppColors.green700, fontWeight: FontWeight.w500)),
                        const Icon(Icons.arrow_drop_down, size: 18, color: AppColors.green700),
                      ]),
                    ),
                    IconButton(icon: const Icon(Icons.copy, size: 16), tooltip: 'Copy', onPressed: () { Clipboard.setData(ClipboardData(text: s.url)); _flash('Link copied'); }),
                    IconButton(icon: const Icon(Icons.delete_outline, size: 16, color: AppColors.filePdf), tooltip: 'Revoke', onPressed: () => _revokeLink(s)),
                  ]),
                )),
          ],
        ]),
        ),
      ),
    );
  }

  String _roleLabel(DriveRole r) => '${r.name[0].toUpperCase()}${r.name.substring(1)}';

  String _linkVerb(DriveRole r) => switch (r) {
        DriveRole.editor => 'Can edit',
        DriveRole.commenter => 'Can comment',
        _ => 'Can view',
      };
}
