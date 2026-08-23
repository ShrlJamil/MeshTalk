import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

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
                          const SizedBox(height: 48),
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
