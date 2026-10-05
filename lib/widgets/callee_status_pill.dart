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
({Color dot, String label, bool isOffline}) calleePresenceMeta(
    String? status) {
  return switch (status) {
    'ready' => (
        dot: MeshLive.connected,
        label: 'Callee · Ready',
        isOffline: false,
      ),
    'waking' => (
        dot: MeshNeutral.textSecondary,
        label: 'Callee · Waking',
        isOffline: false,
      ),
    'in_call' => (
        dot: MeshNeutral.textSecondary,
        label: 'Callee · In call',
        isOffline: false,
      ),
    'offline' => (
        dot: MeshAlert.dangerText,
        label: 'Callee · Offline',
        isOffline: true,
      ),
    _ => (
        dot: MeshNeutral.textFaint,
        label: 'Callee · Checking',
        isOffline: false,
      ),
  };
}

/// Compact single-row status pill for the Callee endpoint.
///
/// The pill is ALWAYS one horizontal row — there is no second row, no
/// detail panel, no accordion, and its height never changes:
///
/// ```text
/// [device] Callee · Ready   72%   Good   38°C        ↻
/// ```
///
/// Tapping the pill (or the refresh icon) requests a fresh snapshot via
/// the existing on-demand flow ([requestCalleeStatus]) and shows the
/// inline metadata for 5 seconds; then only the metadata hides — the
/// pill itself never disappears.
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
      _baselineUpdatedAt = _updatedAt;
    });
    final ok = await requestCalleeStatus();
    if (!mounted) return;
    if (!ok) {
      setState(() => _refreshing = false);
      return;
    }
    _requestTimeoutTimer?.cancel();
    _requestTimeoutTimer = Timer(_requestTimeout, () {
      if (!mounted || !_refreshing) return;
      setState(() => _refreshing = false);
    });
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
        final offline = meta.isOffline;

        final data = _data;
        final battery = data == null ? null : _asMap(data['battery']);
        final network = data == null ? null : _asMap(data['network']);
        final temperature =
            data == null ? null : _asMap(data['temperature']);
        final quality =
            meshQualityFromPayload(network?['quality']?.toString());

        // Inline metadata appears only while the 5s window is open AND a
        // snapshot has actually arrived — never an empty/placeholder row.
        final showStats = _showDetails && data != null;

        return Container(
          decoration: BoxDecoration(
            color: MeshSurface.surface,
            borderRadius: BorderRadius.circular(MeshRadius.pill),
            border: Border.all(color: MeshNeutral.border),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(MeshRadius.pill),
            onTap: _onPillTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                  MeshSpace.md, MeshSpace.sm, MeshSpace.xs, MeshSpace.sm),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.smartphone_rounded,
                    size: 16,
                    color: offline
                        ? MeshAlert.dangerText
                        : MeshNeutral.iconMuted,
                  ),
                  const SizedBox(width: MeshSpace.sm),
                  Flexible(
                    child: Text(
                      meta.label,
                      overflow: TextOverflow.ellipsis,
                      style: MeshText.status.copyWith(
                        color: offline
                            ? MeshAlert.dangerText
                            : MeshNeutral.textPrimary,
                      ),
                    ),
                  ),
                  if (showStats) ...[
                    const SizedBox(width: MeshSpace.sm),
                    _InlineStat(
                      icon: Icons.battery_std_rounded,
                      value: _batteryShort(battery),
                      trailing: _isCharging(battery)
                          ? const Icon(
                              Icons.bolt_rounded,
                              size: 11,
                              color: MeshLive.connected,
                            )
                          : null,
                    ),
                    const SizedBox(width: MeshSpace.sm),
                    _InlineStat(
                      icon: Icons.wifi_rounded,
                      value: meshQualityLabel(quality),
                      valueColor: meshQualityColor(quality),
                    ),
                    const SizedBox(width: MeshSpace.sm),
                    _InlineStat(
                      icon: Icons.device_thermostat_rounded,
                      value: _temperatureShort(temperature),
                    ),
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
  }

  static String _batteryShort(Map<Object?, Object?>? battery) {
    final level = _asInt(battery?['level']);
    return level == null ? '—' : '$level%';
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

/// Compact `icon + value` pair inside the single pill row. Fixed-size
/// icon, truncating value — the row never wraps or grows vertically.
class _InlineStat extends StatelessWidget {
  const _InlineStat({
    required this.icon,
    required this.value,
    this.valueColor,
    this.trailing,
  });

  final IconData icon;
  final String value;
  final Color? valueColor;
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
              color: valueColor ?? MeshNeutral.textSecondary,
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
