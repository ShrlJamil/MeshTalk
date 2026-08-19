import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// Plays the short "connection notice" chime (`assets/sounds/notice.mp3`)
/// once, at full volume, routed through the speakerphone, but truncates it to
/// the first [maxPlayDuration] seconds. Playback is non-blocking
/// (fire-and-forget) and the player is disposed automatically as soon as the
/// tone finishes or the 5-second cap is reached, so no audio resources are
/// retained.
class NoticeTonePlayer {
  static const String assetPath = 'sounds/notice.mp3';

  static const Duration maxPlayDuration = Duration(seconds: 5);

  static final AudioContext _audioContext = AudioContext(
    android: AudioContextAndroid(
      isSpeakerphoneOn: true,
      audioMode: AndroidAudioMode.inCommunication,
      contentType: AndroidContentType.speech,
      usageType: AndroidUsageType.voiceCommunication,
      audioFocus: AndroidAudioFocus.gainTransient,
    ),
  );

  AudioPlayer? _player;
  Timer? _stopTimer;

  Future<void> play() async {
    await dispose();
    debugPrint('[MeshTalk] notice tone: starting playback');
    final player = AudioPlayer();
    _player = player;

    player.onPlayerComplete.listen((_) => dispose(), onError: _onStreamError);
    player.onPlayerStateChanged.listen((state) {
      if (state == PlayerState.completed || state == PlayerState.stopped) {
        dispose();
      }
    }, onError: _onStreamError);

    try {
      await player.play(
        AssetSource(assetPath),
        mode: PlayerMode.mediaPlayer,
        volume: 1.0,
        ctx: _audioContext,
      );
      _stopTimer = Timer(maxPlayDuration, _stop);
    } catch (_) {
      await dispose();
    }
  }

  /// Auto-stops playback once the 5-second cap is reached. The following
  /// `stopped` state change triggers the dispose handled above.
  void _stop() {
    _stopTimer?.cancel();
    _stopTimer = null;
    final player = _player;
    if (player != null) {
      unawaited(player.stop());
    }
  }

  /// Never lets a native audio error propagate into the WebRTC flow.
  void _onStreamError(Object error, StackTrace stackTrace) {
    dispose();
  }

  Future<void> dispose() async {
    _stopTimer?.cancel();
    _stopTimer = null;
    final player = _player;
    _player = null;
    if (player != null) {
      await player.dispose();
      debugPrint('[MeshTalk] notice tone: disposed');
    }
  }
}