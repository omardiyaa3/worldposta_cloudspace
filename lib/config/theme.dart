import 'package:flutter/material.dart';

class AppColors {
  // Primary / Brand Greens
  static const Color green900 = Color(0xFF38670A);
  static const Color green800 = Color(0xFF506B2B);
  static const Color green700 = Color(0xFF679A41);
  static const Color green600 = Color(0xFF82A63E);
  static const Color green500 = Color(0xFFBAF38E);
  static const Color greenActiveBg = Color(0x33BAF38E);

  // Neutrals
  static const Color white = Color(0xFFFFFFFF);
  static const Color grey98 = Color(0xFFF8FAFC);
  static const Color grey96 = Color(0xFFF1F5F9);
  static const Color grey91 = Color(0xFFE2E8F0);
  static const Color azure84 = Color(0xFFCBD5E1);
  static const Color azure65 = Color(0xFF94A3B8);
  static const Color azure47 = Color(0xFF64748B);
  static const Color azure17 = Color(0xFF1E293B);

  // Text
  static const Color heading = Color(0xFF1A1B1E);
  static const Color body = Color(0xFF64748B);
  static const Color muted = Color(0xFF94A3B8);
  static const Color disabled = Color(0xFFCBD5E1);

  // File Types
  static const Color filePdf = Color(0xFFDE4040);
  static const Color fileAi = Color(0xFFED8C24);
  static const Color filePsd = Color(0xFF2678DE);
  static const Color fileSvg = Color(0xFF2DB873);
  static const Color filePng = Color(0xFF944FDE);
  static const Color fileSketch = Color(0xFFF2C01A);
  static const Color fileHtml = Color(0xFF339AD9);
  static const Color filePptx = Color(0xFFD95926);
  static const Color fileDocx = Color(0xFF2678DE);
  static const Color fileDefault = Color(0xFF94A3B8);

  // Status
  static const Color online = Color(0xFF2DB873);
  static const Color busy = Color(0xFFDE4040);
  static const Color away = Color(0xFFED8C24);
}

class AppTheme {
  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      fontFamily: 'Inter',
      scaffoldBackgroundColor: AppColors.grey98,
      colorScheme: ColorScheme.light(
        primary: AppColors.green800,
        secondary: AppColors.green700,
        surface: AppColors.white,
        onPrimary: AppColors.white,
        onSecondary: AppColors.white,
        onSurface: AppColors.heading,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.white,
        foregroundColor: AppColors.heading,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(
        color: AppColors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppColors.grey91, width: 1),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.green800,
          foregroundColor: AppColors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.grey96,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
        hintStyle: const TextStyle(color: AppColors.muted),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
      dividerColor: AppColors.grey91,
    );
  }
}

Color getFileTypeColor(String extension) {
  switch (extension.toLowerCase()) {
    case 'pdf':
      return AppColors.filePdf;
    case 'ai':
      return AppColors.fileAi;
    case 'psd':
      return AppColors.filePsd;
    case 'svg':
      return AppColors.fileSvg;
    case 'png':
    case 'jpg':
    case 'jpeg':
    case 'gif':
    case 'webp':
      return AppColors.filePng;
    case 'sketch':
    case 'skt':
      return AppColors.fileSketch;
    case 'html':
    case 'htm':
    case 'css':
    case 'js':
      return AppColors.fileHtml;
    case 'pptx':
    case 'ppt':
      return AppColors.filePptx;
    case 'docx':
    case 'doc':
      return AppColors.fileDocx;
    default:
      return AppColors.fileDefault;
  }
}

String getFileTypeLabel(String extension) {
  switch (extension.toLowerCase()) {
    case 'jpg':
    case 'jpeg':
      return 'JPG';
    case 'htm':
      return 'HTML';
    case 'ppt':
      return 'PPTX';
    case 'doc':
      return 'DOCX';
    default:
      return extension.toUpperCase();
  }
}
