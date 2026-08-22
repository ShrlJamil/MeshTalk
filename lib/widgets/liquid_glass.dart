import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme.dart';

/// Frosted-glass rounded container: BackdropFilter blur + semi-transparent
/// tint + hairline border, resolved from the current [MeshGlassPalette].
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.borderRadius = 24,
    this.padding = const EdgeInsets.all(16),
  });

  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final palette = glassPaletteFor(Theme.of(context).brightness);
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: palette.cardFill,
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(color: palette.cardBorder, width: 1),
            boxShadow: palette.cardShadow.a == 0
                ? null
                : [
                    BoxShadow(
                      color: palette.cardShadow,
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ],
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Small iOS-style pill/badge for call/network status.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final palette = glassPaletteFor(Theme.of(context).brightness);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: palette.textPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Frosted-glass header shared by HomeScreen and CallScreen: title, a
/// status pill, and the Light/Dark toggle button.
class GlassAppBar extends StatelessWidget {
  const GlassAppBar({
    super.key,
    required this.title,
    required this.statusLabel,
    required this.statusColor,
  });

  final String title;
  final String statusLabel;
  final Color statusColor;

  @override
  Widget build(BuildContext context) {
    final palette = glassPaletteFor(Theme.of(context).brightness);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: GlassPanel(
        borderRadius: 20,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Text(
              title,
              style: TextStyle(
                color: palette.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(width: 10),
            StatusPill(label: statusLabel, color: statusColor),
            const Spacer(),
            _ThemeToggleButton(palette: palette),
          ],
        ),
      ),
    );
  }
}

class _ThemeToggleButton extends StatelessWidget {
  const _ThemeToggleButton({required this.palette});

  final MeshGlassPalette palette;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) {
        final isDark = mode == ThemeMode.dark;
        return Tooltip(
          message: isDark ? 'Beralih ke Light Mode' : 'Beralih ke Dark Mode',
          child: IconButton(
            onPressed: () {
              themeModeNotifier.value = isDark ? ThemeMode.light : ThemeMode.dark;
            },
            icon: Icon(
              isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
              color: palette.textPrimary,
            ),
          ),
        );
      },
    );
  }
}

/// Extra-large (~90px by default) circular Liquid Glass icon button with a
/// micro-label underneath. Wrapped in a [Tooltip] — Flutter's default
/// trigger for `Tooltip` on touch devices is already long-press.
class GlassCircleButton extends StatelessWidget {
  const GlassCircleButton({
    super.key,
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onPressed,
    this.diameter = 90,
    this.tint,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback? onPressed;
  final double diameter;

  /// Optional accent tint (e.g. [kDangerColor] for Hangup). Defaults to the
  /// palette's neutral glass tint.
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final palette = glassPaletteFor(Theme.of(context).brightness);
    final iconColor = tint ?? palette.textPrimary;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: tooltip,
          child: ClipOval(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Container(
                width: diameter,
                height: diameter,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: tint != null ? tint!.withValues(alpha: 0.18) : palette.cardFill,
                  border: Border.all(
                    color: (tint ?? palette.cardBorder).withValues(
                      alpha: tint != null ? 0.55 : 1,
                    ),
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: (tint ?? kAccentColor).withValues(alpha: 0.25),
                      blurRadius: 24,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: Material(
                  color: Colors.transparent,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: onPressed,
                    child: Center(
                      child: Icon(icon, size: diameter * 0.42, color: iconColor),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          label,
          style: TextStyle(
            color: palette.textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
          ),
        ),
      ],
    );
  }
}

/// Floating capsule "control dock" (Mute / Hangup / Audio-output), iOS Glass
/// style: sigma-15 blur per spec. Fill/border stay theme-adaptive
/// ([MeshGlassPalette]) rather than a hardcoded white tint, so the capsule
/// stays visible in Light Mode too, not just Dark Mode.
class GlassDock extends StatelessWidget {
  const GlassDock({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final palette = glassPaletteFor(Theme.of(context).brightness);
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          decoration: BoxDecoration(
            color: palette.cardFill,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: palette.cardBorder, width: 1),
            boxShadow: palette.cardShadow.a == 0
                ? null
                : [
                    BoxShadow(
                      color: palette.cardShadow,
                      blurRadius: 24,
                      offset: const Offset(0, 10),
                    ),
                  ],
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: children),
        ),
      ),
    );
  }
}

/// Compact circular icon button for [GlassDock] — a smaller variant of
/// [GlassCircleButton] with no micro-label, sized for a horizontal dock.
class GlassDockButton extends StatelessWidget {
  const GlassDockButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.diameter = 54,
    this.iconSize = 24,
    this.tint,
    this.active = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double diameter;
  final double iconSize;

  /// Accent tint for a permanently-emphasized button (e.g. Hangup = red).
  final Color? tint;

  /// Whether a toggle button is currently "on" (e.g. mic muted) — tints the
  /// icon/fill with [tint] (or the neutral accent) only while true.
  final bool active;

  @override
  Widget build(BuildContext context) {
    final palette = glassPaletteFor(Theme.of(context).brightness);
    final disabled = onPressed == null;
    final accent = tint ?? kAccentColor;
    final emphasized = tint != null || active;
    final iconColor = disabled
        ? palette.textSecondary.withValues(alpha: 0.5)
        : (emphasized ? accent : palette.textPrimary);

    return Opacity(
      opacity: disabled ? 0.4 : 1,
      child: Tooltip(
        message: tooltip,
        child: ClipOval(
          child: Container(
            width: diameter,
            height: diameter,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: emphasized ? accent.withValues(alpha: 0.18) : Colors.transparent,
            ),
            child: Material(
              color: Colors.transparent,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onPressed,
                child: Center(child: Icon(icon, size: iconSize, color: iconColor)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Soft decorative background glows so the BackdropFilter blur in
/// [GlassPanel]/[GlassCircleButton] has something visible to diffuse, even
/// over an otherwise flat Scaffold background.
class GlassBackdrop extends StatelessWidget {
  const GlassBackdrop({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = glassPaletteFor(Theme.of(context).brightness);
    return IgnorePointer(
      child: Stack(
        children: [
          Positioned(top: -80, right: -60, child: _glow(220, palette.backgroundGlowA)),
          Positioned(bottom: -100, left: -80, child: _glow(260, palette.backgroundGlowB)),
        ],
      ),
    );
  }

  Widget _glow(double size, Color color) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(colors: [color, color.withValues(alpha: 0)]),
      ),
    );
  }
}
