import 'package:flutter/material.dart';

const Color kPrimaryColor = Color(0xFF350074);
const Color kSecondaryColor = Color(0xFF01FAFE);
const Color kSurfaceColor = Color(0xFF0B001A);

ThemeData buildMeshTalkTheme() {
  final colorScheme = ColorScheme.fromSeed(
    seedColor: kPrimaryColor,
    brightness: Brightness.dark,
    primary: kPrimaryColor,
    secondary: kSecondaryColor,
    surface: kSurfaceColor,
  ).copyWith(
    onPrimary: Colors.white,
    onSecondary: kPrimaryColor,
    onSurface: Colors.white,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: kSurfaceColor,
    appBarTheme: const AppBarTheme(
      backgroundColor: kPrimaryColor,
      foregroundColor: Colors.white,
      centerTitle: true,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: kSecondaryColor,
        foregroundColor: kPrimaryColor,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: kSecondaryColor,
        side: const BorderSide(color: kSecondaryColor, width: 1.5),
      ),
    ),
  );
}
