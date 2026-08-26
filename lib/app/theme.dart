import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A dark surface that gets out of the way of the pixels it is showing.
///
/// This app's entire job is letting someone judge image quality, so the chrome
/// has to be neutral enough not to bias that judgement. Near-black rather than
/// pure black, because pure black next to a video makes everything look
/// artificially contrasty; one accent, used sparingly, so nothing competes with
/// the media for attention.
class CrispTheme {
  const CrispTheme._();

  static const bg = Color(0xFF0A0B0E);
  static const surface = Color(0xFF14161C);
  static const surfaceHigh = Color(0xFF1D2029);
  static const border = Color(0xFF2A2E3A);
  static const accent = Color(0xFF4DA3FF);
  static const good = Color(0xFF35D6A0);
  static const warn = Color(0xFFFFB454);
  static const textPrimary = Color(0xFFF2F4F8);
  static const textMuted = Color(0xFF8B93A7);

  static const space1 = 4.0;
  static const space2 = 8.0;
  static const space3 = 12.0;
  static const space4 = 16.0;
  static const space5 = 20.0;
  static const space6 = 24.0;
  static const space8 = 32.0;

  static const radius = 14.0;
  static const radiusLg = 20.0;

  static ThemeData build() {
    const scheme = ColorScheme.dark(
      primary: accent,
      onPrimary: Color(0xFF04121F),
      secondary: good,
      onSecondary: Color(0xFF04121F),
      surface: bg,
      onSurface: textPrimary,
      onSurfaceVariant: textMuted,
      outline: border,
      error: Color(0xFFFF6B6B),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      canvasColor: bg,
      splashFactory: InkSparkle.splashFactory,
      textTheme: _text,
      appBarTheme: const AppBarTheme(
        backgroundColor: bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        systemOverlayStyle: SystemUiOverlayStyle.light,
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 17,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
      ),
      // Depth from tonal fill and a hairline, never shadow — shadows read as
      // grime against dark surfaces.
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: const BorderSide(color: border),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: const Color(0xFF04121F),
          minimumSize: const Size.fromHeight(52),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: textPrimary,
          minimumSize: const Size.fromHeight(52),
          side: const BorderSide(color: border),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
          ),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: surfaceHigh,
        contentTextStyle: TextStyle(color: textPrimary),
        behavior: SnackBarBehavior.floating,
      ),
      dividerTheme: const DividerThemeData(color: border, thickness: 1, space: 1),
    );
  }

  static const _text = TextTheme(
    headlineSmall: TextStyle(
      color: textPrimary,
      fontSize: 24,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.5,
    ),
    titleMedium: TextStyle(
      color: textPrimary,
      fontSize: 16,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.2,
    ),
    bodyMedium: TextStyle(color: textPrimary, fontSize: 14, height: 1.45),
    bodySmall: TextStyle(color: textMuted, fontSize: 13, height: 1.4),
    labelSmall: TextStyle(
      color: textMuted,
      fontSize: 11,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.4,
    ),
  );
}
