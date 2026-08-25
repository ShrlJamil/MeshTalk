import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Top-level callback required by flutter_foreground_task's isolate entry
/// point. MeshTalk's Standby foreground service runs a coarse periodic
/// heartbeat (see [ForegroundServiceController]) as a fallback socket
/// keep-alive; it otherwise has no other periodic work of its own.
@pragma('vm:entry-point')
void _standbyServiceCallback() {
  FlutterForegroundTask.setTaskHandler(_StandbyTaskHandler());
}

/// Payload sent from the task isolate to the main isolate on every heartbeat
/// tick. The task isolate has no access to [SignalingService]/
/// `FirebaseDatabase.instance` (they live in the main isolate), so it can
/// only ping the main isolate via [FlutterForegroundTask.sendDataToMain] and
/// let [ForegroundServiceController._handleTaskData] forward it.
const String _heartbeatMessage = 'meshtalk_standby_heartbeat';

class _StandbyTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {
    FlutterForegroundTask.sendDataToMain(_heartbeatMessage);
  }

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

  /// Fallback keep-alive cadence: on a phone left fully idle for hours, the
  /// only paths that force an RTDB socket refresh (app resume, a
  /// connectivity-type change, a `.info/connected` drop) never fire on their
  /// own — nobody touches the phone and the network type never changes. This
  /// coarse periodic nudge exists purely to bound the worst case even if
  /// every reactive path above stays silent. 15 minutes is deliberately not
  /// tighter than that: it is a safety net, not the primary recovery path.
  static const Duration _heartbeatInterval = Duration(minutes: 15);

  bool _initialized = false;

  /// Invoked on the main isolate every [_heartbeatInterval] while the
  /// Standby service is running. Set by [SignalingService] to trigger a
  /// forced RTDB socket refresh; left unset this is simply never called.
  void Function()? onHeartbeat;

  void _ensureInitialized() {
    if (_initialized) return;
    _initialized = true;
    FlutterForegroundTask.addTaskDataCallback(_handleTaskData);
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
        eventAction: ForegroundTaskEventAction.repeat(
          _heartbeatInterval.inMilliseconds,
        ),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  /// Forwards a heartbeat tick from the task isolate to [onHeartbeat]. Any
  /// other payload is ignored — this channel is reserved for the heartbeat
  /// signal only.
  void _handleTaskData(Object data) {
    if (data != _heartbeatMessage) return;
    debugPrint('[MeshTalk] Standby heartbeat tick received from foreground task');
    onHeartbeat?.call();
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
