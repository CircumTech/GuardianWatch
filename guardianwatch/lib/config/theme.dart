// ─── lib/config/theme.dart ──────────────────────────────────────────────────

import 'package:flutter/material.dart';

class AppTheme {
  AppTheme._();

  // ─────────────────────────────────────────────────────────────────────────
  // Guardian Brand Colors
  // ─────────────────────────────────────────────────────────────────────────

  static const Color primary = Color(0xFF00B4D8);
  static const Color secondary = Color(0xFF0077B6);
  static const Color error = Color(0xFFE63946);

  // Status colors — align with quality flags in BleConstants
  static const Color statusGood = Color(0xFF2A9D8F);
  static const Color statusWarn = Color(0xFFF4A261);
  static const Color statusBad = Color(0xFFE63946);

  // Light surfaces
  static const Color lightBackground = Color(0xFFF7F9FC);
  static const Color lightSurface = Color(0xFFFFFFFF);

  // Dark surfaces
  static const Color darkBackground = Color(0xFF0D0D1A);
  static const Color darkSurface = Color(0xFF1A1A2E);

  // ─────────────────────────────────────────────────────────────────────────
  // Light Theme
  // ─────────────────────────────────────────────────────────────────────────

  static ThemeData get light {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: primary,
          brightness: Brightness.light,
        ).copyWith(
          primary: primary,
          secondary: secondary,
          error: error,
          surface: lightSurface,
        );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: lightBackground,

      appBarTheme: AppBarTheme(
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: lightBackground,
        surfaceTintColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
      ),

      cardTheme: CardThemeData(
        elevation: 0,
        color: lightSurface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: lightSurface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: error, width: 1.5),
        ),
      ),

      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        elevation: 0,
        backgroundColor: lightSurface,
        selectedItemColor: primary,
        unselectedItemColor: scheme.onSurfaceVariant,
      ),

      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
      ),

      chipTheme: ChipThemeData(
        backgroundColor: lightSurface,
        side: BorderSide(color: scheme.outlineVariant),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Dark Theme
  // ─────────────────────────────────────────────────────────────────────────

  static ThemeData get dark {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: primary,
          brightness: Brightness.dark,
        ).copyWith(
          primary: primary,
          secondary: secondary,
          error: error,
          surface: darkSurface,
        );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: darkBackground,

      appBarTheme: AppBarTheme(
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: darkBackground,
        surfaceTintColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
      ),

      cardTheme: CardThemeData(
        elevation: 0,
        color: darkSurface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: darkSurface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: error, width: 1.5),
        ),
      ),

      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        elevation: 0,
        backgroundColor: darkSurface,
        selectedItemColor: primary,
        unselectedItemColor: Colors.white60,
      ),

      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
      ),

      chipTheme: ChipThemeData(
        backgroundColor: darkSurface,
        side: BorderSide(color: scheme.outlineVariant),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }
}
