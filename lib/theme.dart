import 'package:flutter/material.dart';

/// Single accent color used for glow / active / "connected" state across
/// both Light and Dark glass palettes.
const Color kAccentColor = Color(0xFF01FAFE);

/// iOS system-red equivalent, reserved for the Hangup control.
const Color kDangerColor = Color(0xFFFF453A);

/// App-wide theme mode, toggled from the glass header on either screen.
/// A plain top-level [ValueNotifier] (rather than a state-management
/// package) is enough for a single binary Light/Dark switch shared by two
/// screens.
final ValueNotifier<ThemeMode> themeModeNotifier =
    ValueNotifier<ThemeMode>(ThemeMode.dark);

/// Every color the Liquid Glass widgets need, resolved once per brightness
/// so screens never hardcode a `Colors.*` value that would look wrong in
/// the other mode.
class MeshGlassPalette {
  const MeshGlassPalette({
    required this.background,
    required this.backgroundGlowA,
    required this.backgroundGlowB,
    required this.cardFill,
    required this.cardBorder,
    required this.cardShadow,
    required this.textPrimary,
    required this.textSecondary,
  });

  final Color background;
  final Color backgroundGlowA;
  final Color backgroundGlowB;
  final Color cardFill;
  final Color cardBorder;
  final Color cardShadow;
  final Color textPrimary;
  final Color textSecondary;

  static const dark = MeshGlassPalette(
    background: Color(0xFF0B0E14), // dark slate
    backgroundGlowA: Color(0x2601FAFE),
    backgroundGlowB: Color(0x1A350074),
    cardFill: Color(0x14FFFFFF), // Colors.white.withOpacity(0.08)
    cardBorder: Color(0x33FFFFFF), // semi-transparent white border
    cardShadow: Color(0x00000000), // dark mode relies on glow, not shadow
    textPrimary: Colors.white,
    textSecondary: Colors.white60,
  );

  static const light = MeshGlassPalette(
    background: Color(0xFFF4F5F9), // soft off-white
    backgroundGlowA: Color(0x1A01FAFE),
    backgroundGlowB: Color(0x14350074),
    cardFill: Color(0xA6FFFFFF), // Colors.white.withOpacity(0.65)
    cardBorder: Color(0x1F000000),
    cardShadow: Color(0x1A1C1C1E), // soft shadow
    textPrimary: Color(0xFF1C1C1E),
    textSecondary: Color(0xFF6E6E73),
  );
}

MeshGlassPalette glassPaletteFor(Brightness brightness) =>
    brightness == Brightness.dark ? MeshGlassPalette.dark : MeshGlassPalette.light;

ThemeData buildMeshTalkTheme(Brightness brightness) {
  final palette = glassPaletteFor(brightness);
  final colorScheme = ColorScheme.fromSeed(
    seedColor: kAccentColor,
    brightness: brightness,
    primary: kAccentColor,
    surface: palette.background,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: palette.background,
  );
}
