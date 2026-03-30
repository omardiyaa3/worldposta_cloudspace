import 'package:flutter/material.dart';
import '../config/theme.dart';

class FileTypeBadge extends StatelessWidget {
  final String extension;
  final double size;

  const FileTypeBadge({
    super.key,
    required this.extension,
    this.size = 32,
  });

  @override
  Widget build(BuildContext context) {
    final color = getFileTypeColor(extension);
    final label = getFileTypeLabel(extension);

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Center(
        child: Text(
          label,
          style: TextStyle(
            fontSize: size * 0.28,
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
      ),
    );
  }
}

class FileIcon extends StatelessWidget {
  final String extension;
  final bool isDirectory;
  final Color? folderColor;
  final double size;

  const FileIcon({
    super.key,
    required this.extension,
    this.isDirectory = false,
    this.folderColor,
    this.size = 40,
  });

  @override
  Widget build(BuildContext context) {
    if (isDirectory) {
      return Icon(
        Icons.folder,
        size: size,
        color: folderColor ?? AppColors.green800,
      );
    }
    return FileTypeBadge(extension: extension, size: size);
  }
}
