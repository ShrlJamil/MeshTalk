import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Shows a dedicated, high-importance "incoming call" notification when an
/// `incoming_call` FCM wake-up arrives (see
/// `firebaseMessagingBackgroundHandler` in `signaling_service.dart`).
///
/// Deliberately NOT done by adding a `notification` block to the Worker's
/// FCM payload: Android/FCM auto-displays notification (or combined
/// notification+data) messages itself while the app is backgrounded or
/// terminated, and does NOT invoke the Flutter background handler in that
/// case — which is exactly the Standby state this whole wake-up mechanism
/// targets. Keeping the FCM payload data-only (see `worker/index.js`) is
/// what guarantees `firebaseMessagingBackgroundHandler` keeps running; this
/// controller then shows the notification manually, from inside that
/// handler, after the fact.
///
/// Uses `flutter_local_notifications` specifically, rather than a
/// hand-rolled platform channel like [ScreenWakeController]/
/// [ForegroundServiceController]'s tone players do: FlutterFire's headless
/// background `FlutterEngine` — the one `firebaseMessagingBackgroundHandler`
/// actually runs on — auto-registers every declared pub.dev plugin via
/// `GeneratedPluginRegistrant`, but has no knowledge of ad-hoc channels
/// wired up only inside `MainActivity.configureFlutterEngine` (that engine
/// is never constructed for a headless background execution). A hand-rolled
/// channel would silently fail (`MissingPluginException`) from this
/// handler; a real plugin does not have that problem. See the Phase 3 audit
/// notes for the full explanation — this same gap likely affects
/// `ScreenWakeController` today too, flagged there as a separate, future
/// fix rather than addressed here.
class IncomingCallNotificationController {
  static const String channelId = 'meshtalk_incoming_call';
  static const String _channelName = 'Panggilan Masuk';
  static const String _channelDescription =
      'Notifikasi saat ada panggilan masuk ke MeshTalk.';
  static const int _notificationId = 4202;

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Creates the dedicated incoming-call channel, high importance (distinct
  /// from `meshtalk_standby`'s low-importance persistent service channel —
  /// reusing that one is deliberately avoided, see Phase 3 notes).
  /// Idempotent: recreating a channel with the same id is a no-op on
  /// Android, so this is safe to call both at app startup (main isolate,
  /// see `main.dart`) and defensively from [show] itself — a fresh headless
  /// isolate handling a wake-up has no memory of any prior initialization.
  Future<void> ensureChannel() async {
    if (!_isAndroid) return;
    try {
      const androidChannel = AndroidNotificationChannel(
        channelId,
        _channelName,
        description: _channelDescription,
        importance: Importance.high,
      );
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(androidChannel);
    } catch (error) {
      debugPrint(
        '[MeshTalk] incoming-call channel setup failed (continuing anyway): $error',
      );
    }
  }

  /// Shows the "incoming call" notification. Fully error-isolated and
  /// fire-and-forget from the caller's perspective, matching
  /// [ScreenWakeController.wake]'s reasoning: a failure here (notification
  /// permission not granted, odd OEM ROM behavior) must never block or
  /// delay the incoming-call wake-up handshake itself.
  Future<void> show() async {
    if (!_isAndroid) return;
    try {
      await ensureChannel();
      await _plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
      );
      await _plugin.show(
        _notificationId,
        'MeshTalk',
        'Panggilan masuk',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            channelId,
            _channelName,
            channelDescription: _channelDescription,
            importance: Importance.high,
            priority: Priority.high,
            category: AndroidNotificationCategory.call,
          ),
        ),
      );
    } catch (error) {
      debugPrint(
        '[MeshTalk] incoming-call notification failed (continuing anyway): $error',
      );
    }
  }
}
