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
                          const SizedBox(height: 32),
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
