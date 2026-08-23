import 'dart:ui';

import 'package:flutter/material.dart';

import '../services/signaling_service.dart';
import '../theme.dart';

/// Diagonal "specular highlight" edge — a gradient border (bright white ->
/// transparent grey -> soft white) used by every Liquid Glass surface
/// instead of a flat single-color border, so the glass edge reads as a
/// reflective, lit rim rather than a plain outline.
///
/// Implemented with the standard 1px gradient-padding technique: an outer
/// [Container] painted with the diagonal [LinearGradient] as its
/// background, holding an inner [Container] with the real fill color
/// offset by [borderWidth] — leaving only that margin of the gradient
/// visible as a ring. This only changes how the surface itself is
/// *painted*; it never wraps or clips a [BackdropFilter], so a blur applied
/// further up the tree (as every caller here does) is completely
/// unaffected by it.
class _SpecularBorder extends StatelessWidget {
  const _SpecularBorder({
    required this.child,
    required this.fillColor,
    this.borderRadius = 0,
    this.shape = BoxShape.rectangle,
    this.boxShadow,
    this.size,
  });

  /// Ring thickness — the visible slice of the diagonal gradient.
  static const double _borderWidth = 1.2;

  final Widget child;
  final Color fillColor;
  final double borderRadius;
  final BoxShape shape;
  final List<BoxShadow>? boxShadow;

  /// Fixed outer width/height, for circular buttons with a known diameter.
  /// Leave null to size from [child] + its own padding instead (cards/dock).
  final double? size;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final gradientColors = isDark
        ? [
            Colors.white.withValues(alpha: 0.35),
            Colors.white.withValues(alpha: 0.05),
            Colors.white.withValues(alpha: 0.25),
          ]
        : [
            Colors.white.withValues(alpha: 0.8),
            Colors.grey.withValues(alpha: 0.2),
            Colors.white.withValues(alpha: 0.6),
          ];
    final isCircle = shape == BoxShape.circle;
    final innerRadius = (borderRadius - _borderWidth).clamp(0.0, borderRadius);

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: shape,
        borderRadius: isCircle ? null : BorderRadius.circular(borderRadius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: gradientColors,
        ),
        boxShadow: boxShadow,
      ),
      padding: const EdgeInsets.all(_borderWidth),
      child: Container(
        decoration: BoxDecoration(
          shape: shape,
          borderRadius: isCircle ? null : BorderRadius.circular(innerRadius),
          color: fillColor,
        ),
        child: child,
      ),
    );
  }
}

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
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: _SpecularBorder(
          borderRadius: borderRadius,
          fillColor: palette.cardFill,
          boxShadow: palette.cardShadow.a == 0
              ? null
              : [
                  BoxShadow(
                    color: palette.cardShadow,
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ],
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// Frosted-glass header shared by HomeScreen and CallScreen: title and the
/// Light/Dark toggle button. An optional [center] widget (e.g.
/// [DynamicLivePill] on CallScreen) is layered in the same [Stack] as the
/// title/toggle [Row] — rather than floated as an independently-positioned
/// overlay with a hand-tuned offset — so it shares the exact same vertical
/// bounds and is trivially centered via `Alignment.center`.
class GlassAppBar extends StatelessWidget {
  const GlassAppBar({super.key, required this.title, this.center});

  final String title;
  final Widget? center;

  @override
  Widget build(BuildContext context) {
    final palette = glassPaletteFor(Theme.of(context).brightness);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: GlassPanel(
        borderRadius: 20,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Row(
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
                const Spacer(),
                _ThemeToggleButton(palette: palette),
              ],
            ),
            ?center,
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
              child: _SpecularBorder(
                size: diameter,
                shape: BoxShape.circle,
                fillColor: tint != null ? tint!.withValues(alpha: 0.18) : palette.cardFill,
                boxShadow: [
                  BoxShadow(
                    color: (tint ?? kAccentColor).withValues(alpha: 0.25),
                    blurRadius: 24,
                    spreadRadius: 1,
                  ),
                ],
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
        child: _SpecularBorder(
          borderRadius: 999,
          fillColor: palette.cardFill,
          boxShadow: palette.cardShadow.a == 0
              ? null
              : [
                  BoxShadow(
                    color: palette.cardShadow,
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            child: Row(mainAxisSize: MainAxisSize.min, children: children),
          ),
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

const TextStyle _kPillText = TextStyle(
  color: Colors.white,
  fontSize: 13,
  fontWeight: FontWeight.w600,
);

const TextStyle _kPillMono = TextStyle(
  color: Colors.white,
  fontSize: 13,
  fontWeight: FontWeight.w700,
  fontFamily: 'monospace',
  letterSpacing: 0.5,
);

/// iOS "Dynamic Island" / Live Activity style status pill. Floats
/// independently of any header/app bar. In the Idle state it's just clean
/// text with no wrapping box; for every other [SignalingState] it fluidly
/// expands (via [AnimatedSize]) into a dense glass capsule, cross-fading
/// its inner icon+text (via [AnimatedSwitcher]) as the state changes —
/// replacing the old rigid bordered "status box + glowing dot" pattern.
class DynamicLivePill extends StatelessWidget {
  const DynamicLivePill({
    super.key,
    required this.state,
    required this.formattedDuration,
    this.idleLabel = 'MeshTalk',
  });

  final SignalingState state;

  /// Only shown while [state] is [SignalingState.connected].
  final String formattedDuration;

  final String idleLabel;

  bool get _isActive => state != SignalingState.idle;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final palette = glassPaletteFor(Theme.of(context).brightness);
    // Dense/near-opaque black glass regardless of Light/Dark palette — a
    // Dynamic Island capsule reads as a system-level overlay, not a themed
    // app card, so it deliberately does NOT use MeshGlassPalette.cardFill.
    final capsuleColor =
        isDark ? Colors.black.withValues(alpha: 0.65) : Colors.black.withValues(alpha: 0.85);

    return AnimatedSize(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      alignment: Alignment.center,
      child: _isActive
          ? ClipRRect(
              key: const ValueKey('live-pill-active'),
              borderRadius: BorderRadius.circular(999),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                // AnimatedSize (rather than AnimatedContainer) drives the
                // fluid capsule resize as inner content width changes
                // (e.g. "Memanggil..." -> "01:24"), since _SpecularBorder
                // itself is a plain, non-implicitly-animated widget.
                child: AnimatedSize(
                  duration: const Duration(milliseconds: 320),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.center,
                  child: _SpecularBorder(
                    borderRadius: 999,
                    fillColor: capsuleColor,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        transitionBuilder: (child, animation) => FadeTransition(
                          opacity: animation,
                          child: ScaleTransition(scale: animation, child: child),
                        ),
                        child: _content(),
                      ),
                    ),
                  ),
                ),
              ),
            )
          : Padding(
              key: const ValueKey('live-pill-idle'),
              padding: const EdgeInsets.symmetric(vertical: 9),
              child: Text(
                idleLabel,
                style: TextStyle(
                  color: palette.textPrimary.withValues(alpha: 0.7),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2,
                ),
              ),
            ),
    );
  }

  Widget _content() {
    switch (state) {
      case SignalingState.idle:
        return const SizedBox.shrink(key: ValueKey('none'));
      case SignalingState.connecting:
        return const Row(
          key: ValueKey('connecting'),
          mainAxisSize: MainAxisSize.min,
          children: [
            _PillPulseDot(),
            SizedBox(width: 8),
            Text('Memanggil...', style: _kPillText),
          ],
        );
      case SignalingState.connected:
        return Row(
          key: const ValueKey('connected'),
          mainAxisSize: MainAxisSize.min,
          children: [
            const _PillDot(color: Color(0xFF32D74B)),
            const SizedBox(width: 8),
            Text(formattedDuration, style: _kPillMono),
          ],
        );
      case SignalingState.failed:
        return const Row(
          key: ValueKey('failed'),
          mainAxisSize: MainAxisSize.min,
          children: [
            _PillDot(color: Color(0xFFFF453A)),
            SizedBox(width: 8),
            Text('Terputus', style: _kPillText),
          ],
        );
      case SignalingState.disconnected:
        return const Row(
          key: ValueKey('disconnected'),
          mainAxisSize: MainAxisSize.min,
          children: [
            _PillDot(color: Colors.orangeAccent),
            SizedBox(width: 8),
            Text('Terputus', style: _kPillText),
          ],
        );
    }
  }
}

/// Small static status dot with a soft glow — the micro icon for
/// Connected/Failed/Disconnected inside [DynamicLivePill].
class _PillDot extends StatelessWidget {
  const _PillDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 6)],
      ),
    );
  }
}

/// Small looping pulse animation — the mini pulse icon for the Connecting
/// state inside [DynamicLivePill].
class _PillPulseDot extends StatefulWidget {
  const _PillPulseDot();

  @override
  State<_PillPulseDot> createState() => _PillPulseDotState();
}

class _PillPulseDotState extends State<_PillPulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: Tween(begin: 0.6, end: 1.0).animate(
        CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
      ),
      child: const DecoratedBox(
        decoration: BoxDecoration(color: Colors.white70, shape: BoxShape.circle),
        child: SizedBox(width: 8, height: 8),
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
