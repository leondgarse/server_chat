import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  // Colors
  static const Color primaryBlue = Color(0xFF0D33F2);
  static const Color backgroundLight = Color(0xFFF5F6F8);
  static const Color backgroundDark = Color(0xFF101322);
  static const Color surfaceLight = Color(0xFFF1F5F9);
  static const Color surfaceDark = Color(0xFF1E293B);
  static const Color borderLight = Color(0xFFE2E8F0);
  static const Color borderDark = Color(0xFF334155);
  static const Color textPrimaryLight = Color(0xFF0F172A);
  static const Color textPrimaryDark = Color(0xFFF8FAFC);
  static const Color textSecondary = Color(0xFF64748B);

  static ThemeData get lightTheme {
    return ThemeData(
      brightness: Brightness.light,
      primaryColor: primaryBlue,
      scaffoldBackgroundColor: backgroundLight,
      colorScheme: const ColorScheme.light(
        primary: primaryBlue,
        surface: surfaceLight,
        onSurface: textPrimaryLight,
      ),
      textTheme: GoogleFonts.spaceGroteskTextTheme(ThemeData.light().textTheme).copyWith(
        titleLarge: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.bold, letterSpacing: -0.5, color: textPrimaryLight),
        labelSmall: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w500, letterSpacing: 1.5, color: textSecondary),
        bodyMedium: GoogleFonts.spaceGrotesk(color: textPrimaryLight),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: backgroundLight,
        elevation: 0,
        iconTheme: IconThemeData(color: primaryBlue),
        titleTextStyle: TextStyle(color: textPrimaryLight, fontSize: 20, fontWeight: FontWeight.bold, fontFamily: 'Space Grotesk'),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: backgroundLight,
        selectedItemColor: primaryBlue,
        unselectedItemColor: textSecondary,
        showUnselectedLabels: true,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryBlue,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          padding: const EdgeInsets.symmetric(vertical: 16),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        fillColor: surfaceLight,
        filled: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: borderLight),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: borderLight),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: primaryBlue, width: 2),
        ),
      ),
    );
  }

  static ThemeData get darkTheme {
    return ThemeData(
      brightness: Brightness.dark,
      primaryColor: primaryBlue,
      scaffoldBackgroundColor: backgroundDark,
      colorScheme: const ColorScheme.dark(
        primary: primaryBlue,
        surface: surfaceDark,
        onSurface: textPrimaryDark,
      ),
      textTheme: GoogleFonts.spaceGroteskTextTheme(ThemeData.dark().textTheme).copyWith(
        titleLarge: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.bold, letterSpacing: -0.5, color: textPrimaryDark),
        labelSmall: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w500, letterSpacing: 1.5, color: textSecondary),
        bodyMedium: GoogleFonts.spaceGrotesk(color: textPrimaryDark),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: backgroundDark,
        elevation: 0,
        iconTheme: IconThemeData(color: primaryBlue),
        titleTextStyle: TextStyle(color: textPrimaryDark, fontSize: 20, fontWeight: FontWeight.bold, fontFamily: 'Space Grotesk'),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: backgroundDark,
        selectedItemColor: primaryBlue,
        unselectedItemColor: textSecondary,
        showUnselectedLabels: true,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryBlue,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          padding: const EdgeInsets.symmetric(vertical: 16),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        fillColor: surfaceDark,
        filled: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: borderDark),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: borderDark),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: primaryBlue, width: 2),
        ),
      ),
    );
  }
}
