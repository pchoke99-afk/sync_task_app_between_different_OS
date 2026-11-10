import 'package:flutter/material.dart';

/// One palette for tasks, authentication, dialogs, and the assistant.
final appTheme = ThemeData(
  useMaterial3: true,
  brightness: Brightness.dark,
  colorScheme: ColorScheme.fromSeed(
    seedColor: const Color(0xFF599EFF),
    brightness: Brightness.dark,
    surface: const Color(0xFF101722),
  ),
  scaffoldBackgroundColor: const Color(0xFF0C121C),
  appBarTheme: const AppBarTheme(
    backgroundColor: Color(0xFF0C121C),
    surfaceTintColor: Colors.transparent,
    centerTitle: false,
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: const Color(0xFF172232),
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: Color(0xFF35445B)),
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
  ),
  cardTheme: CardThemeData(
    elevation: 0,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
  ),
  dividerTheme: const DividerThemeData(color: Color(0xFF263346)),
  floatingActionButtonTheme: const FloatingActionButtonThemeData(
    backgroundColor: Color(0xFF284D7C),
    foregroundColor: Color(0xFFDFEDFF),
  ),
);
