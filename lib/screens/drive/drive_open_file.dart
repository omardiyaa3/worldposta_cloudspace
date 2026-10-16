// drive_open_file.dart — one rule for opening a Drive file, used by every list
// (files, search, dashboard): Office formats open in Collabora, everything
// else in the preview. Same set as the web app (OfficeEditModal OFFICE_EXTS),
// so e.g. CSV opens as a spreadsheet on every client.
import 'package:flutter/material.dart';

import '../../models/drive_file.dart';
import 'drive_file_preview.dart';
import 'drive_office_editor.dart';

const Set<String> driveOfficeExtensions = {
  'docx', 'docm', 'doc', 'dotx', 'dotm', 'dot', 'odt', 'rtf',
  'xlsx', 'xlsm', 'xlsb', 'xls', 'ods', 'csv',
  'pptx', 'pptm', 'ppt', 'ppsx', 'ppsm', 'pps', 'potx', 'potm', 'pot', 'odp',
};

bool isDriveOfficeFile(DriveFile f) => !f.isDirectory && driveOfficeExtensions.contains(f.extension);

/// Opens [f] in the Office editor or the preview. Folders are the caller's job.
Future<void> openDriveFile(BuildContext context, DriveFile f) {
  return Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => isDriveOfficeFile(f) ? DriveOfficeEditor(file: f) : DriveFilePreview(file: f),
  ));
}
