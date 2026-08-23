import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Bridges to native `ScreenWakeManager` (see `MainActivity.kt`) to force
/// the physical display panel out of deep sleep the instant an incoming
/// offer arrives on the Callee. The existing `setShowWhenLocked`/
/// `setTurnScreenOn` window flags only take effect once the Activity is
/// actually resumed — on a fully screen-off device that's not enough on its
/// own, so the native side additionally acquires a short, self-releasing
/// `PowerManager.WakeLock` with the legacy screen-wake flags. Non-Android
/// platforms are a no-op.
class ScreenWakeController {
  static const MethodChannel _channel = MethodChannel('meshtalk/screen_wake');

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Fire-and-forget by design at every call site: a failure here (missing
  /// permission, odd OEM ROM behavior) must never block or delay the
  /// incoming-call handshake itself.
  Future<void> wake() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<void>('wakeScreen');
    } catch (error) {
      debugPrint('[MeshTalk] screen wake failed (call continues): $error');
    }
  }
}
