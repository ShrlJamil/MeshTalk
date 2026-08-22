import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Plays the short "connection notice" chime (`assets/sounds/notice.mp3`)
/// once, via a native Android `SoundPool` reached through [_channel].
///
/// This deliberately bypasses the `audioplayers` package: its Android
/// implementation (`WrappedPlayer.updateAudioContext`) writes directly to the
/// global `android.media.AudioManager` (`setMode` / `setSpeakerphoneOn`) on
/// every playback, regardless of which `AudioContextAndroid` values are
/// passed. That collides with the WebRTC call's `MODE_IN_COMMUNICATION`
/// session and can silently break the callee's mic/speaker route (confirmed
/// on Realme C12). `SoundPool` never touches `AudioManager` mode,
/// speakerphone state, or audio focus, so playback here can never disturb
/// the active call. Non-Android platforms are a no-op.
class NoticeTonePlayer {
  static const MethodChannel _channel = MethodChannel('meshtalk/notice_tone');

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> play() async {
    if (!_isAndroid) return;
    debugPrint('[MeshTalk] notice tone: starting playback');
    try {
      await _channel.invokeMethod<void>('play');
    } catch (error) {
      debugPrint('[MeshTalk] notice tone: play failed (call continues): $error');
    }
  }

  Future<void> dispose() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {
      // Never let a native audio error propagate into the WebRTC flow.
    }
  }
}
