/// This package has **no Dart API**.
///
/// Its only job is to register the native `meshtalk/tts` and
/// `meshtalk/message_ringtone` `MethodChannel`s (backed by `TtsSpeaker` and
/// `MessageRingtonePlayer`) on every `FlutterEngine` the app spins up —
/// including the headless engine that `firebase_messaging` creates for
/// `onBackgroundMessage`, where `MainActivity`-scoped channels are not
/// available. That is what lets the Phase 1 announcement pipeline (message
/// ringtone → Android TTS) also run while the Callee is in standby /
/// background / Doze.
///
/// Callers keep using the app-side `AnnouncementService` /
/// `MessageRingtonePlayer` Dart wrappers — the channel names are unchanged.
library;
