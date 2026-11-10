import 'package:flutter/material.dart';

/// One palette for tasks, authentication, dialogs, and the assistant.
final appTheme = ThemeData(
  useMaterial3: true,
  brightness: Brightness.dark,
  colorScheme:
      ColorScheme.fromSeed(
        seedColor: const Color(0xFF599EFF),
        brightness: Brightness.dark,
        surface: const Color(0xFF09090B),
      ).copyWith(
        surfaceContainerLowest: const Color(0xFF000000),
        surfaceContainerLow: const Color(0xFF101012),
        surfaceContainer: const Color(0xFF161618),
        surfaceContainerHigh: const Color(0xFF1C1C20),
        surfaceContainerHighest: const Color(0xFF242428),
        outline: const Color(0xFF505058),
        outlineVariant: const Color(0xFF303036),
      ),
  scaffoldBackgroundColor: const Color(0xFF000000),
  appBarTheme: const AppBarTheme(
    backgroundColor: Color(0xFF000000),
    surfaceTintColor: Colors.transparent,
    centerTitle: false,
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: const Color(0xFF141416),
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: Color(0xFF35353B)),
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
  ),
  cardTheme: CardThemeData(
    elevation: 0,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
  ),
  dividerTheme: const DividerThemeData(color: Color(0xFF2A2A30)),
  floatingActionButtonTheme: const FloatingActionButtonThemeData(
    backgroundColor: Color(0xFF152A42),
    foregroundColor: Color(0xFFDFEDFF),
  ),
);
