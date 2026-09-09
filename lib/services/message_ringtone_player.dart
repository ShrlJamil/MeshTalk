import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Plays the short "announcement incoming" ringtone
/// (`assets/sounds/message_ringtone.mp3`) via a native Android `MediaPlayer`
/// (see `MessageRingtonePlayer.kt`) and completes its [play] Future only
/// when playback has actually finished — so the Announcement flow can start
/// TTS strictly after the ringtone, with no arbitrary delay.
///
/// Deliberately separate from [NoticeTonePlayer] / [HangupTonePlayer], which
/// use `SoundPool` and are left untouched — `SoundPool` exposes no
/// end-of-playback callback. The native side sets the same `AudioAttributes`
/// (`USAGE_MEDIA` / `CONTENT_TYPE_SONIFICATION`) and never touches
/// `AudioManager` mode / speakerphone / audio focus, so it cannot disturb an
/// active WebRTC call. Non-Android platforms are a no-op.
class MessageRingtonePlayer {
  static const MethodChannel _channel =
      MethodChannel('meshtalk/message_ringtone');

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Resolves when the ringtone finishes (or fails, or is stopped, or a
  /// native duration-derived watchdog fires). Never throws — a playback
  /// failure still completes normally so the caller can proceed to TTS.
  Future<void> play() async {
    if (!_isAndroid) return;
    debugPrint('[Announcement] message ringtone: starting playback');
    try {
      await _channel.invokeMethod<void>('play');
      debugPrint('[Announcement] message ringtone: playback finished');
    } catch (error) {
      debugPrint(
        '[Announcement] message ringtone: playback failed (continuing): $error',
      );
    }
  }

  /// Force-stops the ringtone. Never throws.
  Future<void> stop() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {
      // Never let a native audio error propagate into the call flow.
    }
  }
}
