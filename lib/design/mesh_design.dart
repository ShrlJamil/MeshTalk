import 'package:flutter/material.dart';

/// Phase A redesign foundation: centralized semantic design tokens for
/// MeshTalk's solid-dark visual direction (see `assets/FigmaDesign/`).
///
/// This file is purely additive. Nothing here is consumed by the current
/// HomeScreen/CallScreen yet — Phase B/C will migrate screens onto these
/// tokens. The legacy glass system in `lib/theme.dart` and
/// `lib/widgets/liquid_glass.dart` is intentionally left untouched so
/// existing screens keep rendering exactly as before.
///
/// Frozen (never put here): WebRTC, signaling, RTDB, FCM, TTS, ringtone,
/// audio routing, foreground service, presence, status-request flow.

// ---------------------------------------------------------------------------
// Semantic colors
// ---------------------------------------------------------------------------

/// Primary MeshTalk identity + primary actions.
class MeshBrand {
  const MeshBrand._();

  /// Base brand purple. Very dark — suited for light surfaces or as an
  /// identity accent, NOT as a button fill on near-black backgrounds.
  static const Color primary = Color(0xFF350074);

  /// Same hue, lifted for contrast as a solid CTA fill on dark surfaces
  /// (matches the `Call Callee` action in `assets/FigmaDesign/caller.png`).
  /// Not a new accent — same purple family, one step lighter.
  static const Color primaryAction = Color(0xFF4A0E9E);
}

/// Live/positive state: connected, ready, active, refreshing.
class MeshLive {
  const MeshLive._();

  static const Color connected = Color(0xFF01FAFE);
}

/// Destructive/offline state: offline, end call, errors, unavailable.
class MeshAlert {
  const MeshAlert._();

  /// Solid red fill for the End Call action
  /// (matches `assets/FigmaDesign/active call(caller).png`).
  static const Color danger = Color(0xFFE5484D);

  /// Text/icon red on dark surfaces (offline pill, failure states).
  static const Color dangerText = Color(0xFFFF6B6B);
}

/// Neutral grayscale ramp for informational content, secondary controls,
/// audio controls, completed/disabled states and supporting UI.
class MeshNeutral {
  const MeshNeutral._();

  static const Color textPrimary = Color(0xFFF2F3F5);
  static const Color textSecondary = Color(0xFF9BA0AB);
  static const Color textFaint = Color(0xFF6B7078);
  static const Color icon = Color(0xFFC6CAD2);
  static const Color iconMuted = Color(0xFF8A8F99);
  static const Color border = Color(0xFF23262E);
}

// ---------------------------------------------------------------------------
// Surfaces (dark only — the Figma direction is dark; no light tokens in
// Phase A). Do NOT make every component a card; these levels exist so
// Phase B/C can choose deliberately.
// ---------------------------------------------------------------------------

class MeshSurface {
  const MeshSurface._();

  /// App background. Reuses the existing dark scaffold value so the
  /// foundation stays consistent with the running app.
  static const Color background = Color(0xFF0B0E14);

  /// Primary surface: status pill, app bar, sheets.
  static const Color surface = Color(0xFF14161D);

  /// Secondary/elevated surface: announcement row, info cards, route card.
  static const Color surfaceElevated = Color(0xFF1A1D25);

  /// Control surface: toggles, selector chips (e.g. Caller|Callee),
  /// pressed/active segment.
  static const Color control = Color(0xFF242832);

  /// Disabled surface for inactive controls.
  static const Color disabled = Color(0xFF1A1D24);
  static const Color disabledText = Color(0xFF6E737D);
}

// ---------------------------------------------------------------------------
// Typography (system font — no new font dependency)
// ---------------------------------------------------------------------------

class MeshText {
  const MeshText._();

  /// Large screen headline (`Ready when you are.`). Light weight, tight.
  static const TextStyle pageTitle = TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.w300,
    letterSpacing: -0.5,
    color: MeshNeutral.textPrimary,
    height: 1.2,
  );

  /// Card/section title (`Call Callee`, endpoint name).
  static const TextStyle title = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w600,
    color: MeshNeutral.textPrimary,
    height: 1.3,
  );

  /// Section label inside secondary rows (`Announcement`).
  static const TextStyle section = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    color: MeshNeutral.textPrimary,
    height: 1.35,
  );

  /// Body copy.
  static const TextStyle body = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    color: MeshNeutral.textPrimary,
    height: 1.45,
  );

  /// Supporting text under headlines and rows.
  static const TextStyle supporting = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w400,
    color: MeshNeutral.textSecondary,
    height: 1.4,
  );

  /// Small eyebrow-kind label (`Intercom`, `Outgoing intercom`).
  /// Sentence case only — never uppercase via styling.
  static const TextStyle eyebrow = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    color: MeshNeutral.textFaint,
    height: 1.4,
  );

  /// Status pill text (`Callee online`, `Call connected`).
  static const TextStyle status = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    color: MeshNeutral.textPrimary,
    height: 1.3,
  );

  /// Secondary fragment inside a status pill (`Clear signal`).
  static const TextStyle statusSecondary = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w400,
    color: MeshNeutral.textSecondary,
    height: 1.3,
  );

  /// Primary/danger button label (`Call Callee`, `End call`).
  static const TextStyle action = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    color: Colors.white,
    height: 1.3,
  );

  /// Small metadata: status detail values, counters, captions.
  static const TextStyle metadata = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    color: MeshNeutral.textSecondary,
    height: 1.4,
  );

  /// Call timer. Tabular figures keep `00:17` from jittering; no custom
  /// monospace font dependency.
  static TextStyle timer({Color color = MeshLive.connected}) => TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w500,
        color: color,
        fontFeatures: const [FontFeature.tabularFigures()],
        height: 1.3,
      );
}

// ---------------------------------------------------------------------------
// Spacing / radius / control sizes
// ---------------------------------------------------------------------------

class MeshSpace {
  const MeshSpace._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

/// Restrained radii. Rectangular controls use sm/md (see Figma: CTA and
/// cards are ~10-14px, not capsules). `pill` remains only for fully
/// circular icon affordances — never for bars, controls or cards.
class MeshRadius {
  const MeshRadius._();

  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double sheet = 20;
  static const double pill = 999;
}

class MeshSize {
  const MeshSize._();

  /// Full-width primary/danger action height (`Call Callee`, `End call`).
  static const double primaryButtonHeight = 60;

  /// Minimum touch target for icon buttons.
  static const double iconButton = 48;

  /// Compact in-pill refresh affordance.
  static const double compactControl = 32;

  /// Flat status indicator dot. Solid fill, no glow (see [MeshStatusDot]).
  static const double statusDot = 8;

  /// Standard screen horizontal margin.
  static const double screenMargin = 20;

  /// Max content width so large phones don't stretch rows edge to edge.
  static const double maxContentWidth = 460;
}

// ---------------------------------------------------------------------------
// Network quality (status representation contract for Phase B/C)
//
// Quality describes CONNECTION QUALITY, never transport type. The RTDB
// payload already carries both `type` and `quality`; future UI must lead
// with quality and map the raw `poor` value to the user-facing `Weak`.
// ---------------------------------------------------------------------------

/// User-facing connection quality, in display order.
enum MeshNetworkQuality { good, fair, weak, offline, unknown }

/// Maps a raw `network.quality` payload string to display quality.
/// Raw `poor` (link-signal terminology) becomes user-facing `weak`.
MeshNetworkQuality meshQualityFromPayload(String? raw) {
  return switch (raw) {
    'good' => MeshNetworkQuality.good,
    'fair' => MeshNetworkQuality.fair,
    'poor' => MeshNetworkQuality.weak,
    'offline' => MeshNetworkQuality.offline,
    _ => MeshNetworkQuality.unknown,
  };
}

/// User-facing label per quality. Transport types (`Wi-Fi`, `Cellular`,
/// ...) must never be shown as the quality value.
String meshQualityLabel(MeshNetworkQuality quality) {
  return switch (quality) {
    MeshNetworkQuality.good => 'Good',
    MeshNetworkQuality.fair => 'Fair',
    MeshNetworkQuality.weak => 'Weak',
    MeshNetworkQuality.offline => 'Offline',
    MeshNetworkQuality.unknown => 'Unknown',
  };
}

/// Semantic dot color per quality. `fair`/`weak` stay neutral-amber-free:
/// informational, not alarming — red is reserved for offline/failure.
Color meshQualityColor(MeshNetworkQuality quality) {
  return switch (quality) {
    MeshNetworkQuality.good => MeshLive.connected,
    MeshNetworkQuality.fair => MeshNeutral.textSecondary,
    MeshNetworkQuality.weak => MeshNeutral.textSecondary,
    MeshNetworkQuality.offline => MeshAlert.dangerText,
    MeshNetworkQuality.unknown => MeshNeutral.textFaint,
  };
}

// ---------------------------------------------------------------------------
// Role + endpoint terminology (Phase B/C naming contract)
//
// Roles are `Caller` and `Callee`. Never introduce `House` terminology.
// Endpoints are devices, represented with a device/smartphone visual —
// never a house icon.
// ---------------------------------------------------------------------------

class MeshTerms {
  const MeshTerms._();

  static const String caller = 'Caller';
  static const String callee = 'Callee';
  static const String callCallee = 'Call Callee';
  static const String announcement = 'Announcement';
}

// ---------------------------------------------------------------------------
// Minimal solid primitives (stateless, no behavior, no listeners)
//
// Genuinely reusable building blocks for Phase B/C. Existing screens do
// NOT use these yet — that migration is Phase B/C work.
// ---------------------------------------------------------------------------

/// Flat solid status dot. No glow, no shadow — glow was a glass-era
/// decoration and must not return.
class MeshStatusDot extends StatelessWidget {
  const MeshStatusDot({super.key, required this.color, this.size = MeshSize.statusDot});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// Button/row styles shared by Phase B/C. Solid fills, restrained radius,
/// no gradients, no glow shadows.
class MeshControls {
  const MeshControls._();

  static ButtonStyle primaryAction() {
    return FilledButton.styleFrom(
      backgroundColor: MeshBrand.primaryAction,
      foregroundColor: Colors.white,
      minimumSize: const Size.fromHeight(MeshSize.primaryButtonHeight),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(MeshRadius.md),
      ),
      textStyle: MeshText.action,
    );
  }

  static ButtonStyle danger() {
    return FilledButton.styleFrom(
      backgroundColor: MeshAlert.danger,
      foregroundColor: Colors.white,
      minimumSize: const Size.fromHeight(MeshSize.primaryButtonHeight),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(MeshRadius.md),
      ),
      textStyle: MeshText.action,
    );
  }

  static ButtonStyle secondary() {
    return FilledButton.styleFrom(
      backgroundColor: MeshSurface.surfaceElevated,
      foregroundColor: MeshNeutral.textPrimary,
      minimumSize: const Size.fromHeight(MeshSize.primaryButtonHeight),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(MeshRadius.md),
      ),
      textStyle: MeshText.action,
    );
  }
}

/// Dark Material theme carrying the Mesh tokens, for Phase B/C to adopt.
/// NOT wired into `main.dart` in Phase A — wiring it now would restyle
/// the running glass screens, which is explicitly out of scope.
ThemeData buildMeshTheme() {
  const scheme = ColorScheme.dark(
    primary: MeshBrand.primaryAction,
    onPrimary: Colors.white,
    secondary: MeshLive.connected,
    error: MeshAlert.danger,
    onError: Colors.white,
    surface: MeshSurface.surface,
    onSurface: MeshNeutral.textPrimary,
    surfaceContainerHighest: MeshSurface.surfaceElevated,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: MeshSurface.background,
    filledButtonTheme: FilledButtonThemeData(style: MeshControls.secondary()),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: MeshNeutral.icon,
        minimumSize: const Size.square(MeshSize.iconButton),
      ),
    ),
    dividerColor: MeshNeutral.border,
  );
}
