import 'package:flutter/material.dart';

/// Posta Drive design tokens — the same values as the web app
/// (drive-ai web/src/styles.css), so the apps and the web look like one product.
class AppColors {
  // Brand greens (--accent family).
  static const Color green900 = Color(0xFF3D6B1F); // --accent-text
  static const Color green800 = Color(0xFF4F7D2F); // --accent-hover
  static const Color green700 = Color(0xFF679A41); // --accent (PRIMARY)
  static const Color green600 = Color(0xFF81C343); // bright accent
  static const Color green500 = Color(0xFFB4E07A); // light accent
  static const Color greenActiveBg = Color(0x1A679A41); // --accent-bg (selected rows/nav)

  // Surfaces and lines.
  static const Color white = Color(0xFFFFFFFF); // --panel
  static const Color page = Color(0xFFF3F5F7); // --bg (app background)
  static const Color grey98 = Color(0xFFF9F9F9); // --panel-2 (hover, subtle bg)
  static const Color grey96 = Color(0xFFF8F8F8); // --panel-3 (nested cards)
  static const Color grey91 = Color(0xFFE5E7EB); // --border
  static const Color azure84 = Color(0xFFB8BBC2); // --border-2 / --text-3
  static const Color azure65 = Color(0xFF9AA0A6);
  static const Color azure47 = Color(0xFF64748B);
  static const Color azure17 = Color(0xFF1E293B);

  // Text (--text / --text-2): one navy for headings and body, grey for labels.
  static const Color heading = Color(0xFF293C51);
  static const Color body = Color(0xFF293C51);
  static const Color muted = Color(0xFF798592);
  static const Color disabled = Color(0xFFB8BBC2);

  // File types — same colours as the web app's and the emails' type badges.
  static const Color filePdf = Color(0xFFE85263); // also --danger
  static const Color fileAi = Color(0xFFBA7517); // --warning (Posta gold)
  static const Color filePsd = Color(0xFF4EA3E0); // --info
  static const Color fileSvg = Color(0xFF20B884);
  static const Color filePng = Color(0xFF4EA3E0); // images
  static const Color fileSketch = Color(0xFFBA7517);
  static const Color fileHtml = Color(0xFF0EA5E9);
  static const Color filePptx = Color(0xFFC43E1C);
  static const Color fileDocx = Color(0xFF2B579A);
  static const Color fileXlsx = Color(0xFF217346);
  static const Color fileMedia = Color(0xFF7B5EA7);
  static const Color fileDefault = Color(0xFF798592);

  // Status
  static const Color online = Color(0xFF679A41);
  static const Color busy = Color(0xFFE85263);
  static const Color away = Color(0xFFBA7517);
}

/// Body text in Heebo, headings in Public Sans (the web app's two fonts).
const String _bodyFont = 'Heebo';
const String _displayFont = 'PublicSans';

class AppTheme {
  static ThemeData get lightTheme {
    final base = ThemeData(useMaterial3: true, fontFamily: _bodyFont);
    TextStyle? display(TextStyle? t, {FontWeight w = FontWeight.w700}) =>
        t?.copyWith(fontFamily: _displayFont, fontWeight: w, color: AppColors.heading, letterSpacing: -0.2);
    final textTheme = base.textTheme
        .apply(bodyColor: AppColors.body, displayColor: AppColors.heading)
        .copyWith(
          displayLarge: display(base.textTheme.displayLarge),
          displayMedium: display(base.textTheme.displayMedium),
          displaySmall: display(base.textTheme.displaySmall),
          headlineLarge: display(base.textTheme.headlineLarge),
          headlineMedium: display(base.textTheme.headlineMedium),
          headlineSmall: display(base.textTheme.headlineSmall),
          titleLarge: display(base.textTheme.titleLarge, w: FontWeight.w600),
        );
    final radius8 = BorderRadius.circular(8);
    return base.copyWith(
      scaffoldBackgroundColor: AppColors.page,
      textTheme: textTheme,
      colorScheme: const ColorScheme.light(
        primary: AppColors.green700,
        onPrimary: AppColors.white,
        primaryContainer: AppColors.greenActiveBg,
        onPrimaryContainer: AppColors.green900,
        secondary: AppColors.green800,
        onSecondary: AppColors.white,
        surface: AppColors.white,
        onSurface: AppColors.heading,
        onSurfaceVariant: AppColors.muted,
        outline: AppColors.grey91,
        outlineVariant: AppColors.grey91,
        error: AppColors.filePdf,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.white,
        foregroundColor: AppColors.heading,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        shape: const Border(bottom: BorderSide(color: AppColors.grey91)),
        titleTextStyle: const TextStyle(
            fontFamily: _displayFont, fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.heading),
      ),
      cardTheme: CardThemeData(
        color: AppColors.white,
        elevation: 0,
        margin: EdgeInsets.zero,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: AppColors.grey91),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.green700,
          foregroundColor: AppColors.white,
          disabledBackgroundColor: AppColors.green700.withValues(alpha: 0.45),
          disabledForegroundColor: AppColors.white,
          elevation: 0,
          minimumSize: const Size(64, 44),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
          textStyle: const TextStyle(fontFamily: _bodyFont, fontSize: 15, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(borderRadius: radius8),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.green700,
          foregroundColor: AppColors.white,
          minimumSize: const Size(64, 44),
          textStyle: const TextStyle(fontFamily: _bodyFont, fontSize: 15, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(borderRadius: radius8),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.heading,
          side: const BorderSide(color: AppColors.grey91),
          minimumSize: const Size(64, 44),
          textStyle: const TextStyle(fontFamily: _bodyFont, fontSize: 15, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(borderRadius: radius8),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.green900,
          textStyle: const TextStyle(fontFamily: _bodyFont, fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.white,
        hintStyle: const TextStyle(color: AppColors.muted),
        labelStyle: const TextStyle(color: AppColors.muted),
        floatingLabelStyle: const TextStyle(color: AppColors.green900),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        border: OutlineInputBorder(borderRadius: radius8, borderSide: const BorderSide(color: AppColors.grey91)),
        enabledBorder: OutlineInputBorder(borderRadius: radius8, borderSide: const BorderSide(color: AppColors.grey91)),
        focusedBorder: OutlineInputBorder(borderRadius: radius8, borderSide: const BorderSide(color: AppColors.green700, width: 1.6)),
        errorBorder: OutlineInputBorder(borderRadius: radius8, borderSide: const BorderSide(color: AppColors.filePdf)),
        focusedErrorBorder: OutlineInputBorder(borderRadius: radius8, borderSide: const BorderSide(color: AppColors.filePdf, width: 1.6)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        titleTextStyle: const TextStyle(
            fontFamily: _displayFont, fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.heading),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: AppColors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 6,
        shape: RoundedRectangleBorder(borderRadius: radius8, side: const BorderSide(color: AppColors.grey91)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.heading,
        contentTextStyle: const TextStyle(fontFamily: _bodyFont, color: AppColors.white),
        shape: RoundedRectangleBorder(borderRadius: radius8),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: AppColors.grey98,
        selectedColor: AppColors.greenActiveBg,
        side: const BorderSide(color: AppColors.grey91),
        labelStyle: const TextStyle(fontFamily: _bodyFont, color: AppColors.heading),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: AppColors.muted,
        selectedColor: AppColors.green900,
        selectedTileColor: AppColors.greenActiveBg,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: AppColors.green700, linearTrackColor: AppColors.grey91),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? AppColors.white : null),
        trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? AppColors.green700 : null),
      ),
      dividerTheme: const DividerThemeData(color: AppColors.grey91, thickness: 1, space: 1),
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
    case 'odp':
      return AppColors.filePptx;
    case 'xlsx':
    case 'xls':
    case 'csv':
    case 'ods':
      return AppColors.fileXlsx;
    case 'mp4':
    case 'mov':
    case 'mkv':
    case 'webm':
    case 'mp3':
    case 'wav':
    case 'm4a':
      return AppColors.fileMedia;
    case 'docx':
    case 'doc':
    case 'odt':
    case 'rtf':
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
