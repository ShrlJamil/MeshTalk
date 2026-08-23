import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:proximity_sensor/proximity_sensor.dart';

/// Wraps the `proximity_sensor` package's built-in Android
/// `PROXIMITY_SCREEN_OFF_WAKE_LOCK` control: while active, the OS
/// automatically dims/turns the screen off when the phone is held to the
/// ear (sensor near) and back on when moved away (sensor far), driven by
/// Android's own proximity sensor for as long as the sensor stream stays
/// subscribed. No custom native channel is needed — the plugin's native
/// side already performs the acquire/release.
class ProximityScreenController {
  StreamSubscription<int>? _sub;

  bool get _isActive => _sub != null;

  /// Starts proximity-based screen control. `setProximityScreenOff(true)`
  /// must be called BEFORE subscribing to [ProximitySensor.events]: the
  /// native side only acquires the wake lock at subscribe-time, gated on
  /// that flag already being set. Idempotent — a second call while already
  /// active is a no-op.
  Future<void> start() async {
    if (_isActive) return;
    try {
      await ProximitySensor.setProximityScreenOff(true);
    } catch (error) {
      debugPrint(
        '[MeshTalk] proximity screen-off enable failed (call continues): $error',
      );
      return;
    }
    _sub = ProximitySensor.events.listen(
      (event) {
        final isNear = event > 0;
        debugPrint('[MeshTalk] proximity sensor: ${isNear ? "near" : "far"}');
      },
      onError: (Object error) {
        debugPrint('[MeshTalk] proximity sensor stream error (ignored): $error');
      },
    );
  }

  /// Stops monitoring. Cancelling the stream subscription already makes the
  /// native side release the wake lock (see the plugin's `onCancel`);
  /// explicitly disabling screen-off too is defensive belt-and-suspenders.
  /// Safe to call anytime, including when not active.
  Future<void> stop() async {
    final sub = _sub;
    _sub = null;
    await sub?.cancel();
    try {
      await ProximitySensor.setProximityScreenOff(false);
    } catch (_) {
      // Never let a native error propagate into the WebRTC flow.
    }
  }
}
