import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/signaling_service.dart';
import '../theme.dart';
import '../widgets/liquid_glass.dart';
import 'call_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  Future<void> _enterMode(BuildContext context, CallMode mode) async {
    var status = await Permission.microphone.request();
    if (status.isPermanentlyDenied) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'Izin mikrofon diblokir permanen. Buka pengaturan untuk mengizinkan akses mikrofon.',
          ),
          action: SnackBarAction(
            label: 'Buka Pengaturan',
            onPressed: openAppSettings,
          ),
        ),
      );
      return;
    }

    if (!status.isGranted) {
      status = await Permission.microphone.request();
    }

    if (!status.isGranted) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Izin mikrofon dibutuhkan untuk menggunakan interkom.'),
        ),
      );
      return;
    }

    // Standby keeps a Firebase listener alive in the background waiting for
    // an incoming offer — without a battery-optimization exemption, Android
    // (and especially MIUI/Realme UI) can freeze that listener within
    // minutes. `.status` already makes this effectively "ask once": once
    // granted, every future Standby entry is a no-op check.
    if (mode == CallMode.callee) {
      if (!context.mounted) return;
      await _requestBatteryOptimizationExemption(context);
      // On Android 13+, POST_NOTIFICATIONS is a runtime permission — without
      // it, neither the Standby foreground-service notification nor the
      // dedicated incoming-call notification (IncomingCallNotificationController)
      // can actually display. `.request()` is a no-op if already granted.
      await Permission.notification.request();
    }

    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => CallScreen(mode: mode)),
    );
  }

  /// Phase 2: lets the Caller broadcast a spoken announcement to the house
  /// WITHOUT starting a call. Just an RTDB write + Worker standby-wake (see
  /// [publishAnnouncement]) — no mic permission, no WebRTC, no CallScreen.
  Future<void> _promptAnnouncement(BuildContext context) async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Umumkan ke Rumah'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: SignalingService.maxAnnouncementLength,
          minLines: 1,
          maxLines: 3,
          textInputAction: TextInputAction.send,
          decoration: const InputDecoration(
            hintText: 'Contoh: Tolong buka pintu depan',
          ),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Batal'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Kirim'),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmed = text?.trim() ?? '';
    if (trimmed.isEmpty || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await publishAnnouncement(trimmed);
    messenger.showSnackBar(
      SnackBar(
        content: Text(ok ? 'Pengumuman terkirim' : 'Gagal mengirim pengumuman'),
      ),
    );
  }

  Future<void> _requestBatteryOptimizationExemption(BuildContext context) async {
    final status = await Permission.ignoreBatteryOptimizations.status;
    if (status.isGranted) return;

    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Agar panggilan masuk tetap diterima saat layar mati, izinkan '
          'MeshTalk berjalan tanpa optimasi baterai.',
        ),
        duration: Duration(seconds: 4),
      ),
    );
    await Permission.ignoreBatteryOptimizations.request();
  }

  @override
  Widget build(BuildContext context) {
    final palette = glassPaletteFor(Theme.of(context).brightness);
    return Scaffold(
      backgroundColor: palette.background,
      body: Stack(
        children: [
          const Positioned.fill(child: GlassBackdrop()),
          SafeArea(
            child: Column(
              children: [
                const GlassAppBar(title: 'MeshTalk'),
                Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Pilih Mode Interkom',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: palette.textPrimary,
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Panggilan Langsung',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: palette.textSecondary, fontSize: 13),
                          ),
                          const SizedBox(height: 16),
                          const _HousePresenceBadge(),
                          const SizedBox(height: 12),
                          const _HouseStatusCard(),
                          const SizedBox(height: 28),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              GlassCircleButton(
                                icon: Icons.headset_mic_rounded,
                                label: 'Standby',
                                tooltip: 'Aktifkan Standby (Auto-Answer)',
                                tint: kStandbyAccentColor,
                                onPressed: () => _enterMode(context, CallMode.callee),
                              ),
                              const SizedBox(width: 32),
                              GlassCircleButton(
                                icon: Icons.call_rounded,
                                label: 'Call',
                                tooltip: 'Mulai Panggilan',
                                tint: kCallAccentColor,
                                onPressed: () => _enterMode(context, CallMode.caller),
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          TextButton.icon(
                            onPressed: () => _promptAnnouncement(context),
                            icon: const Icon(Icons.campaign_rounded, size: 18),
                            label: const Text('Umumkan ke Rumah'),
                            style: TextButton.styleFrom(
                              foregroundColor: palette.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Real-time read-only view of the Callee's Presence (see
/// `SignalingService._registerPresence`) — lets the Caller (Poco) see
/// whether the house phone is actually reachable before pressing "Call",
/// instead of only discovering it after dialing. Reads directly from RTDB
/// rather than through a [SignalingService] instance: [HomeScreen] never
/// creates one itself (only [CallScreen] does, per mode), and Presence is
/// meant to be visible before either mode is entered.
class _HousePresenceBadge extends StatelessWidget {
  const _HousePresenceBadge();

  @override
  Widget build(BuildContext context) {
    final palette = glassPaletteFor(Theme.of(context).brightness);
    return StreamBuilder<DatabaseEvent>(
      stream: FirebaseDatabase.instance
          .ref('${SignalingService.roomPath}/presence/status')
          .onValue,
      builder: (context, snapshot) {
        final status = snapshot.data?.snapshot.value as String?;
        final (color, label) = switch (status) {
          'ready' => (const Color(0xFF32D74B), 'Rumah: Siap'),
          'waking' => (Colors.orangeAccent, 'Rumah: Membangunkan...'),
          'in_call' => (kCallAccentColor, 'Rumah: Sedang Menelepon'),
          'offline' => (kDangerColor, 'Rumah: Offline'),
          _ => (palette.textSecondary, 'Rumah: Memeriksa status...'),
        };
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 6)],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: palette.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Phase 3 (on-demand) — read-only view of the House phone's status snapshot
/// (`intercom_rooms/rumah_utama/callee_status`). Complements
/// [_HousePresenceBadge]: presence answers "is the House reachable", this
/// answers "what state is it in".
///
/// There is NO periodic telemetry. The snapshot only changes when the user
/// taps the refresh button, which writes one `callee_status_request` node
/// ([requestCalleeStatus]); a standby Callee answers by writing one
/// `callee_status` snapshot. This widget subscribes to `callee_status` purely
/// to receive that answer.
///
/// Freshness is decided here on the Caller from `updatedAt` (a server
/// timestamp): `<= 2 min` fresh, older is "Status lama", a missing/malformed
/// node is "Tidak tersedia". A local UI ticker re-evaluates every
/// [_tickerEvery] so the "Diperbarui N lalu" line and the fresh->stale
/// transition update without a new RTDB event — it is a display ticker, not a
/// telemetry publisher.
class _HouseStatusCard extends StatefulWidget {
  const _HouseStatusCard();

  @override
  State<_HouseStatusCard> createState() => _HouseStatusCardState();
}

class _HouseStatusCardState extends State<_HouseStatusCard> {
  static const Duration _tickerEvery = Duration(seconds: 10);

  /// `<= 2 min` since `updatedAt` counts as fresh; older is "Status lama".
  static const int _freshMaxMs = 120 * 1000;

  /// Fallback that clears the loading state if no fresher snapshot arrives
  /// (Callee asleep in Doze, offline, mid-call, etc.).
  static const Duration _requestTimeout = Duration(seconds: 12);

  Timer? _ticker;
  Timer? _requestTimeoutTimer;
  StreamSubscription<DatabaseEvent>? _statusSub;

  Map<Object?, Object?>? _data;
  int? _updatedAt;

  bool _refreshing = false;
  bool _requestFailed = false;

  /// `updatedAt` captured at the moment refresh was tapped — a snapshot with
  /// a strictly greater `updatedAt` is the response to this request.
  int? _baselineUpdatedAt;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(_tickerEvery, (_) {
      if (mounted) setState(() {});
    });
    _statusSub = FirebaseDatabase.instance
        .ref('${SignalingService.roomPath}/callee_status')
        .onValue
        .listen(_onStatusEvent);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _requestTimeoutTimer?.cancel();
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
        _requestFailed = false;
        _requestTimeoutTimer?.cancel();
        _requestTimeoutTimer = null;
      }
    });
  }

  Future<void> _onRefreshTapped() async {
    if (_refreshing) return; // disable-while-pending is the debounce
    setState(() {
      _refreshing = true;
      _requestFailed = false;
      _baselineUpdatedAt = _updatedAt;
    });
    final ok = await requestCalleeStatus();
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _refreshing = false;
        _requestFailed = true;
      });
      return;
    }
    _requestTimeoutTimer?.cancel();
    _requestTimeoutTimer = Timer(_requestTimeout, () {
      if (!mounted || !_refreshing) return;
      setState(() {
        _refreshing = false;
        _requestFailed = true;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = glassPaletteFor(Theme.of(context).brightness);
    final data = _data;
    final updatedAt = _updatedAt;
    final ageMs = updatedAt == null
        ? null
        : DateTime.now().millisecondsSinceEpoch - updatedAt;

    final _Freshness freshness;
    if (data == null || ageMs == null) {
      freshness = _Freshness.unavailable;
    } else if (ageMs > _freshMaxMs) {
      freshness = _Freshness.stale;
    } else {
      freshness = _Freshness.fresh;
    }

    final (dotColor, headLabel) = switch (freshness) {
      _Freshness.fresh => (const Color(0xFF32D74B), 'Terbaru'),
      _Freshness.stale => (Colors.orangeAccent, 'Status lama'),
      _Freshness.unavailable => (palette.textSecondary, 'Tidak tersedia'),
    };

    final showValues = freshness != _Freshness.unavailable;
    final battery = showValues ? _asMap(data?['battery']) : null;
    final network = showValues ? _asMap(data?['network']) : null;
    final temperature = showValues ? _asMap(data?['temperature']) : null;

    final valueColor = freshness == _Freshness.fresh
        ? palette.textPrimary
        : palette.textSecondary;

    final String footer;
    final Color footerColor;
    if (_requestFailed) {
      footer = 'Gagal memperbarui status';
      footerColor = kDangerColor;
    } else if (freshness == _Freshness.unavailable) {
      footer = 'Belum ada data — ketuk ↻ untuk meminta';
      footerColor = palette.textSecondary;
    } else {
      footer = 'Diperbarui ${_ageText(ageMs)}';
      footerColor = palette.textSecondary;
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: GlassPanel(
        borderRadius: 20,
        padding: const EdgeInsets.fromLTRB(18, 10, 10, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: dotColor,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: dotColor.withValues(alpha: 0.6),
                        blurRadius: 6,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'Rumah',
                  style: TextStyle(
                    color: palette.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  headLabel,
                  style: TextStyle(
                    color: dotColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: _refreshing ? null : _onRefreshTapped,
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Perbarui status rumah',
                  icon: _refreshing
                      ? SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: palette.textSecondary,
                          ),
                        )
                      : Icon(
                          Icons.refresh_rounded,
                          size: 18,
                          color: palette.textSecondary,
                        ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            _row(palette, valueColor, 'Baterai', _batteryText(battery)),
            _row(palette, valueColor, 'Jaringan', _networkText(network)),
            _row(palette, valueColor, 'Suhu', _temperatureText(temperature)),
            const SizedBox(height: 8),
            Text(
              footer,
              style: TextStyle(color: footerColor, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(
    MeshGlassPalette palette,
    Color valueColor,
    String label,
    String value,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 78,
            child: Text(
              label,
              style: TextStyle(color: palette.textSecondary, fontSize: 12.5),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: valueColor,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _batteryText(Map<Object?, Object?>? battery) {
    if (battery == null) return '—';
    final level = _asInt(battery['level']);
    final charging = battery['charging'] == true;
    if (level == null) return charging ? 'Mengisi daya' : '—';
    return charging ? '$level% • Mengisi daya' : '$level%';
  }

  static String _networkText(Map<Object?, Object?>? network) {
    if (network == null) return '—';
    final type = network['type']?.toString() ?? 'unknown';
    final quality = network['quality']?.toString() ?? 'unknown';
    final typeLabel = switch (type) {
      'wifi' => 'Wi-Fi',
      'cellular' => 'Seluler',
      'ethernet' => 'Ethernet',
      'vpn' => 'VPN',
      'none' => 'Tidak ada koneksi',
      _ => null,
    };
    final qualityLabel = switch (quality) {
      'good' => 'Baik',
      'fair' => 'Cukup',
      'poor' => 'Lemah',
      'offline' => 'Offline',
      _ => null,
    };
    if (typeLabel == null && qualityLabel == null) return '—';
    if (type == 'none') return 'Tidak ada koneksi';
    if (typeLabel == null) return qualityLabel ?? '—';
    if (qualityLabel == null) return typeLabel;
    return '$typeLabel — $qualityLabel';
  }

  static String _temperatureText(Map<Object?, Object?>? temperature) {
    if (temperature == null) return '—';
    final celsius = _asDouble(temperature['celsius']);
    if (celsius == null) return '—';
    // Label matches the source: this is BATTERY temperature, never CPU.
    return 'Baterai ${celsius.toStringAsFixed(1)}°C';
  }

  static String _ageText(int? ageMs) {
    if (ageMs == null) return 'tidak diketahui';
    final seconds = ageMs ~/ 1000;
    if (seconds < 10) return 'baru saja';
    if (seconds < 60) return '$seconds detik lalu';
    if (seconds < 3600) return '${seconds ~/ 60} menit lalu';
    return '${seconds ~/ 3600} jam lalu';
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

enum _Freshness { fresh, stale, unavailable }
