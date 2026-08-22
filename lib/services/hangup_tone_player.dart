import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Plays the short "call ended" chime (`assets/sounds/hangup_tone.mp3`)
/// once, via the same native Android `SoundPool` mechanism used by
/// `NoticeTonePlayer` (see that file for the full rationale for avoiding
/// the `audioplayers` package). SoundPool never touches `AudioManager`
/// mode, speakerphone state, or audio focus, so playback here can never
/// block or interfere with `cleanupRoom()` / PeerConnection teardown, even
/// when triggered right as a call is ending. Non-Android platforms are a
/// no-op.
class HangupTonePlayer {
  static const MethodChannel _channel = MethodChannel('meshtalk/hangup_tone');

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> play() async {
    if (!_isAndroid) return;
    debugPrint('[MeshTalk] hangup tone: starting playback');
    try {
      await _channel.invokeMethod<void>('play');
    } catch (error) {
      debugPrint('[MeshTalk] hangup tone: play failed (cleanup continues): $error');
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
