import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../design/mesh_design.dart';
import '../services/signaling_service.dart';

/// Maps a raw `presence/status` value to its pill presentation.
///
/// Shared by [CalleeStatusPill] and [HomeScreen] so both agree on what
/// each presence state means without duplicating the mapping.
/// `offline` is informational only — it never gates the `Call Callee`
/// action (the call flow itself handles wake-up/reconnect).
///
/// Only the device icon carries semantic color (cyan when ready, red
/// when offline); all text stays neutral.
({String label, bool isReady, bool isOffline}) calleePresenceMeta(
    String? status) {
  return switch (status) {
    'ready' => (
        label: 'Callee · Ready',
        isReady: true,
        isOffline: false,
      ),
    'waking' => (
        label: 'Callee · Waking',
        isReady: false,
        isOffline: false,
      ),
    'in_call' => (
        label: 'Callee · In call',
        isReady: false,
        isOffline: false,
      ),
    'offline' => (
        label: 'Callee · Offline',
        isReady: false,
        isOffline: true,
      ),
    _ => (
        label: 'Callee · Checking',
        isReady: false,
        isOffline: false,
      ),
  };
}

/// Compact single-row status control for the Callee endpoint.
///
/// ALWAYS one horizontal row with restrained (`md`) corners — never a
/// capsule, second row, detail panel, or accordion; height never changes:
///
/// ```text
/// [device] Callee · Ready   72%   Good   38°C   Update failed ↻
/// [device] Callee · Ready                                     ↻
/// ```
///
/// Only the device icon carries semantic color (cyan ready, red
/// offline); background, border, text and metadata stay neutral.
/// Tapping the control (or refresh) requests a fresh snapshot via the
/// existing on-demand flow ([requestCalleeStatus]) and shows the inline
/// metadata for 5 seconds; then only the metadata hides. A failed
/// request keeps prior data and swaps in a compact `Update failed` chip.
///
/// If the row cannot fit everything, lower-priority items are dropped
/// (temperature → quality → battery; label/refresh/failure stay).
/// Nothing ever wraps.
///
/// Status transport is unchanged: one `callee_status_request` write per
/// tap, answered by a single `callee_status` write from the standby
/// Callee. No polling, no telemetry — the 12s timer is a request-timeout
/// fallback and the 5s timer is a UI-only metadata hide timer.
class CalleeStatusPill extends StatefulWidget {
  const CalleeStatusPill({super.key});

  @override
  State<CalleeStatusPill> createState() => _CalleeStatusPillState();
}

class _CalleeStatusPillState extends State<CalleeStatusPill> {
  /// Clears the refreshing state when no fresher snapshot arrives
  /// (Callee in Doze, offline, mid-call, …).
  static const Duration _requestTimeout = Duration(seconds: 12);

  /// UI-only one-shot: hides the inline metadata 5s after it was shown.
  /// Never touches RTDB/FCM/signaling — it only flips [_showDetails].
  static const Duration _detailsVisibleFor = Duration(seconds: 5);

  Timer? _requestTimeoutTimer;
  Timer? _hideTimer;
  StreamSubscription<DatabaseEvent>? _statusSub;

  Map<Object?, Object?>? _data;
  int? _updatedAt;

  bool _showDetails = false;
  bool _refreshing = false;

  /// UI-only: the latest request failed (request rejected or 12s timeout
  /// with no fresher snapshot). Never conflated with presence — a failed
  /// refresh says nothing about whether the Callee is online. Shown as a
  /// compact chip inside the metadata window; cleared on the next request
  /// or fresh response.
  bool _lastRequestFailed = false;

  /// `updatedAt` seen when refresh was tapped — a snapshot with a strictly
  /// greater `updatedAt` is the answer to this request.
  int? _baselineUpdatedAt;

  @override
  void initState() {
    super.initState();
    _statusSub = FirebaseDatabase.instance
        .ref('${SignalingService.roomPath}/callee_status')
        .onValue
        .listen(_onStatusEvent);
  }

  @override
  void dispose() {
    _requestTimeoutTimer?.cancel();
    _hideTimer?.cancel();
    _statusSub?.cancel();
    super.dispose();
  }

  void _onStatusEvent(DatabaseEvent event) {
    if (!mounted) return;
    final raw = event.snapshot.value;
    final data = raw is Map ? Map<Object?, Object?>.from(raw) : null;
    final updatedAt = _asInt(data?['updatedAt']);

    final gotFreshResponse = _refreshing &&
        updatedAt != null &&
        (_baselineUpdatedAt == null || updatedAt > _baselineUpdatedAt!);

    setState(() {
      _data = data;
      _updatedAt = updatedAt;
      if (gotFreshResponse) {
        _refreshing = false;
        _lastRequestFailed = false;
        _requestTimeoutTimer?.cancel();
        _requestTimeoutTimer = null;
      }
    });
    // A fresh answer to this interaction reveals the inline metadata
    // (with a fresh 5s window), even if the previous window just lapsed.
    if (gotFreshResponse) _showDetailsForAWhile();
  }

  Future<void> _requestRefresh() async {
    if (_refreshing) return; // disable-while-pending is the debounce
    setState(() {
      _refreshing = true;
      _lastRequestFailed = false;
      _baselineUpdatedAt = _updatedAt;
    });
    final ok = await requestCalleeStatus();
    if (!mounted) return;
    if (!ok) {
      setState(() => _refreshing = false);
      _markRequestFailed();
      return;
    }
    _requestTimeoutTimer?.cancel();
    _requestTimeoutTimer = Timer(_requestTimeout, () {
      if (!mounted || !_refreshing) return;
      setState(() => _refreshing = false);
      _markRequestFailed();
    });
  }

  /// Records a failed request and (re)opens the metadata window so the
  /// compact failure chip is actually seen — the 12s timeout can fire
  /// long after the tap's 5s window lapsed. Prior data, if any, stays.
  void _markRequestFailed() {
    if (!mounted) return;
    setState(() => _lastRequestFailed = true);
    _showDetailsForAWhile();
  }

  /// Shows the inline metadata and (re)starts the one-shot 5s hide timer.
  /// Cancels any running timer first so taps can never stack timers.
  void _showDetailsForAWhile() {
    _hideTimer?.cancel();
    if (!mounted) return;
    setState(() => _showDetails = true);
    _hideTimer = Timer(_detailsVisibleFor, () {
      if (!mounted) return;
      setState(() => _showDetails = false);
    });
  }

  void _onPillTap() {
    _requestRefresh();
    _showDetailsForAWhile();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DatabaseEvent>(
      stream: FirebaseDatabase.instance
          .ref('${SignalingService.roomPath}/presence/status')
          .onValue,
      builder: (context, snapshot) {
        final meta =
            calleePresenceMeta(snapshot.data?.snapshot.value as String?);

        final data = _data;
        final battery = data == null ? null : _asMap(data['battery']);
        final network = data == null ? null : _asMap(data['network']);
        final temperature =
            data == null ? null : _asMap(data['temperature']);
        final quality =
            meshQualityFromPayload(network?['quality']?.toString());

        // Metadata lives only inside the 5s window. With prior data the
        // full group shows; with no data yet, only a failure chip can
        // show (never an empty placeholder row).
        final showGroup =
            _showDetails && (data != null || _lastRequestFailed);

        return LayoutBuilder(
          builder: (context, constraints) {
            final maxWidth =
                constraints.maxWidth.isFinite ? constraints.maxWidth : 480.0;

            // Trailing segments in display order, each with a hide
            // priority (higher drops first; the failure chip never drops
            // while the window is open).
            final segments = <_MetaSegment>[];
            if (showGroup) {
              if (data != null) {
                segments.add(_MetaSegment(
                  priority: 4,
                  width: _statWidth(
                      context, Icons.battery_std_rounded,
                      _batteryShort(battery), _isCharging(battery)),
                  builder: () => _InlineStat(
                    icon: Icons.battery_std_rounded,
                    value: _batteryShort(battery),
                    trailing: _isCharging(battery)
                        ? const Icon(
                            Icons.bolt_rounded,
                            size: 11,
                            color: MeshNeutral.iconMuted,
                          )
                        : null,
                  ),
                ));
                segments.add(_MetaSegment(
                  priority: 5,
                  width: _statWidth(context, Icons.wifi_rounded,
                      meshQualityLabel(quality), false),
                  builder: () => _InlineStat(
                    icon: Icons.wifi_rounded,
                    // Quality text stays neutral; the device icon alone
                    // carries state color.
                    value: meshQualityLabel(quality),
                  ),
                ));
                segments.add(_MetaSegment(
                  priority: 6,
                  width: _statWidth(context,
                      Icons.device_thermostat_rounded,
                      _temperatureShort(temperature), false),
                  builder: () => _InlineStat(
                    icon: Icons.device_thermostat_rounded,
                    value: _temperatureShort(temperature),
                  ),
                ));
              }
              _MetaSegment? tail;
              // Failure is the only tail content. The former relative-age
              // slot was deliberately removed: the refresh action itself
              // already communicates "latest status now".
              if (_lastRequestFailed) {
                tail = _MetaSegment(
                  priority: 0, // never dropped while visible
                  width: _textWidth(context, 'Update failed', _metaStyle),
                  builder: () => const Text(
                    'Update failed',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                      color: MeshAlert.dangerText,
                      height: 1.4,
                    ),
                  ),
                );
              }
              if (tail != null) segments.add(tail);
            }

            // Fixed chrome: horizontal padding + device icon + gaps +
            // refresh slot. The label itself stays Flexible (ellipsis),
            // so only a readable minimum is reserved for it here.
            const fixedChrome = 12.0 + 16 + 8 + 4 + 32 + 4;
            const labelMin = 72.0;
            const slack = 12.0;
            var budget = maxWidth - fixedChrome - labelMin - slack;
            final kept = segments.toList();
            kept.sort((a, b) => b.priority.compareTo(a.priority));
            for (final seg in kept.toList()) {
              if (seg.priority != 0 && seg.width > budget) {
                kept.remove(seg);
              } else {
                budget -= seg.width;
              }
            }
            kept.sort((a, b) => segments.indexOf(a).compareTo(segments.indexOf(b)));

            return Container(
              decoration: BoxDecoration(
                color: MeshSurface.surface,
                borderRadius: BorderRadius.circular(MeshRadius.md),
                border: Border.all(color: MeshNeutral.border),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(MeshRadius.md),
                onTap: _onPillTap,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(MeshSpace.md,
                      MeshSpace.sm, MeshSpace.xs, MeshSpace.sm),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.smartphone_rounded,
                        size: 16,
                        // The icon alone carries state color. Everything
                        // else in this control stays neutral.
                        color: meta.isOffline
                            ? MeshAlert.dangerText
                            : (meta.isReady
                                ? MeshLive.connected
                                : MeshNeutral.iconMuted),
                      ),
                      const SizedBox(width: MeshSpace.sm),
                      Flexible(
                        child: Text(
                          meta.label,
                          overflow: TextOverflow.ellipsis,
                          style: MeshText.status,
                        ),
                      ),
                      for (final seg in kept) ...[
                        const SizedBox(width: MeshSpace.sm),
                        Flexible(child: seg.builder()),
                      ],
                      const SizedBox(width: MeshSpace.xs),
                      _RefreshButton(
                        refreshing: _refreshing,
                        onPressed: _onPillTap,
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  static const TextStyle _metaStyle = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    color: MeshNeutral.textSecondary,
    height: 1.4,
  );

  static String _batteryShort(Map<Object?, Object?>? battery) {
    final level = _asInt(battery?['level']);
    return level == null ? '—' : '$level%';
  }

  /// Measures a metadata segment (leading 8px gap + 13px icon + 3px gap +
  /// text + optional bolt) with the real text scaler — no hardcoded
  /// screen widths, adapts to 1.3x text scale.
  static double _statWidth(
      BuildContext context, IconData icon, String value, bool bolt) {
    return 8 + 13 + 3 + _textWidth(context, value, _metaStyle) + (bolt ? 13 : 0);
  }

  static double _textWidth(
      BuildContext context, String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    return painter.width;
  }

  static bool _isCharging(Map<Object?, Object?>? battery) =>
      battery?['charging'] == true;

  static String _temperatureShort(Map<Object?, Object?>? temperature) {
    final celsius = _asDouble(temperature?['celsius']);
    if (celsius == null) return '—';
    // Matches the native source: BATTERY temperature, never CPU.
    return '${celsius.toStringAsFixed(0)}°C';
  }

  static Map<Object?, Object?>? _asMap(Object? value) =>
      value is Map ? Map<Object?, Object?>.from(value) : null;

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '');
  }

  static double? _asDouble(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }
}

/// One trailing metadata slot in the pill row: measured width, hide
/// priority (higher drops first; 0 never drops), and builder.
class _MetaSegment {
  const _MetaSegment({
    required this.priority,
    required this.width,
    required this.builder,
  });

  final int priority;
  final double width;
  final Widget Function() builder;
}

/// Compact `icon + value` pair inside the single pill row. Fixed-size
/// icon, truncating value, always neutral text — the device icon alone
/// carries state color. The row never wraps or grows vertically.
class _InlineStat extends StatelessWidget {
  const _InlineStat({
    required this.icon,
    required this.value,
    this.trailing,
  });

  final IconData icon;
  final String value;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: MeshNeutral.iconMuted),
        const SizedBox(width: 3),
        Flexible(
          child: Text(
            value,
            overflow: TextOverflow.ellipsis,
            style: MeshText.metadata.copyWith(
              fontSize: 12,
              color: MeshNeutral.textSecondary,
            ),
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 2),
          trailing!,
        ],
      ],
    );
  }
}

/// In-pill refresh affordance: spinner while a request is in flight.
class _RefreshButton extends StatelessWidget {
  const _RefreshButton({required this.refreshing, required this.onPressed});

  final bool refreshing;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: MeshSize.compactControl,
      height: MeshSize.compactControl,
      child: refreshing
          ? const Padding(
              padding: EdgeInsets.all(8),
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: MeshLive.connected,
              ),
            )
          : IconButton(
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              tooltip: 'Refresh callee status',
              onPressed: onPressed,
              icon: const Icon(
                Icons.refresh_rounded,
                size: 16,
                color: MeshNeutral.iconMuted,
              ),
            ),
    );
  }
}
