// ─── lib/config/theme.dart ───────────────────────────────────────────────────

import 'package:flutter/material.dart';

class AppTheme {
  static const _primary = Color(0xFF00B4D8);
  static const _secondary = Color(0xFF0077B6);
  static const _error = Color(0xFFE63946);
  static const _surface = Color(0xFF1A1A2E);

  static ThemeData get light {
    final baseScheme = ColorScheme.fromSeed(
      seedColor: _primary,
      brightness: Brightness.light,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: baseScheme.copyWith(
        secondary: _secondary,
        error: _error,
      ),
      scaffoldBackgroundColor: baseScheme.primary,
      appBarTheme: const AppBarTheme(
        centerTitle: true,
        elevation: 0,
      ),
      cardTheme: const CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
        ),
      ),
    );
  }

  static ThemeData get dark {
    final baseScheme = ColorScheme.fromSeed(
      seedColor: _primary,
      brightness: Brightness.dark,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: baseScheme.copyWith(
        surface: _surface,
        secondary: _secondary,
        error: _error,
      ),
      scaffoldBackgroundColor: const Color(0xFF0D0D1A),
      appBarTheme: const AppBarTheme(
        centerTitle: true,
        elevation: 0,
        backgroundColor: Color(0xFF0D0D1A),
      ),
      cardTheme: const CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
        ),
        color: Color(0xFF1A1A2E),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: Color(0xFF1A1A2E),
      ),
    );
  }
}
