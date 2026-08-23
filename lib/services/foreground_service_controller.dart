import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Top-level callback required by flutter_foreground_task's isolate entry
/// point. MeshTalk's Standby foreground service does no periodic work of
/// its own — its only job is to keep the process (and therefore
/// [SignalingService]'s Firebase RTDB `offer` listener) alive while the app
/// is backgrounded, so the task handler is intentionally a no-op.
@pragma('vm:entry-point')
void _standbyServiceCallback() {
  FlutterForegroundTask.setTaskHandler(_StandbyTaskHandler());
}

class _StandbyTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

/// Keeps the process alive while the Callee is in Standby (waiting for an
/// incoming offer) by running a persistent Android foreground service with
/// a visible notification. Without this, Android — and especially
/// MIUI/Realme UI's more aggressive OEM battery managers — freezes or kills
/// the backgrounded process within minutes, silently dropping the Firebase
/// RTDB `offer` listener with no error the app could ever detect.
///
/// Android-only: this app's iOS target has no equivalent Info.plist/
/// background-mode configuration, so [start]/[stop] are no-ops on any
/// non-Android platform.
class ForegroundServiceController {
  static const int _serviceId = 4201;
  static const String _notificationTitle = 'MeshTalk Standby';
  static const String _notificationText = 'Mendengarkan panggilan masuk...';

  bool _initialized = false;

  void _ensureInitialized() {
    if (_initialized) return;
    _initialized = true;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'meshtalk_standby',
        channelName: 'MeshTalk Standby',
        channelDescription:
            'Menjaga koneksi tetap aktif saat mode Standby (Auto-Answer).',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  /// Starts (or refreshes) the Standby notification/service. Fully
  /// error-isolated and fire-and-forget from the caller's perspective: a
  /// failure here (e.g. notification permission denied) must never block or
  /// fail entering Standby itself — it only means the OS keeps the original
  /// background-kill risk in place, which is strictly no worse than before
  /// this feature existed.
  Future<void> start() async {
    if (defaultTargetPlatform != TargetPlatform.android || kIsWeb) return;
    try {
      _ensureInitialized();
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.updateService(
          notificationTitle: _notificationTitle,
          notificationText: _notificationText,
        );
        return;
      }
      final result = await FlutterForegroundTask.startService(
        serviceId: _serviceId,
        notificationTitle: _notificationTitle,
        notificationText: _notificationText,
        callback: _standbyServiceCallback,
      );
      if (result is ServiceRequestFailure) {
        debugPrint('[MeshTalk] foreground service start failed: ${result.error}');
      }
    } catch (error) {
      debugPrint('[MeshTalk] foreground service start failed (continuing anyway): $error');
    }
  }

  /// Stops the Standby service/notification. Safe to call anytime,
  /// including when the service was never started.
  Future<void> stop() async {
    if (defaultTargetPlatform != TargetPlatform.android || kIsWeb) return;
    try {
      if (!await FlutterForegroundTask.isRunningService) return;
      await FlutterForegroundTask.stopService();
    } catch (error) {
      debugPrint('[MeshTalk] foreground service stop failed (continuing anyway): $error');
    }
  }
}
