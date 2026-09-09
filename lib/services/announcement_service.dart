import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Thin wrapper over the native Android Text-to-Speech bridge
/// (`meshtalk/tts` MethodChannel -> `TtsSpeaker.kt`). Mirrors the shape of
/// [NoticeTonePlayer] / [HangupTonePlayer]: Android-only, every error
/// swallowed, no Firebase / UI / WebRTC state of its own.
///
/// Audio safety: the native side never requests audio focus, never calls
/// `AudioManager.setMode()` / `setSpeakerphoneOn()`, never uses
/// `KEY_PARAM_STREAM`, and emits with `USAGE_MEDIA` /
/// `CONTENT_TYPE_SONIFICATION` — so speaking an announcement mixes into the
/// current output route exactly like the notice/hangup tones and cannot
/// disturb an active WebRTC call.
class AnnouncementService {
  static const MethodChannel _channel = MethodChannel('meshtalk/tts');

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Speaks [text]. The returned Future resolves once the native engine
  /// reports the utterance done/failed (or a native watchdog fires), so the
  /// caller can sequence announcements without overlap. Never throws.
  Future<void> speak(String text) async {
    if (!_isAndroid) return;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    debugPrint('[Announcement] starting TTS (len=${trimmed.length})');
    try {
      await _channel.invokeMethod<void>('speak', {'text': trimmed});
      debugPrint('[Announcement] TTS finished');
    } on MissingPluginException catch (error) {
      debugPrint('[Announcement] TTS channel unavailable (skipped): $error');
    } on PlatformException catch (error) {
      debugPrint('[Announcement] TTS speak failed (skipped): $error');
    } catch (error) {
      debugPrint('[Announcement] TTS speak error (skipped): $error');
    }
  }

  /// Cancels any in-flight / queued speech. Never throws.
  Future<void> stop() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {
      // Never let a native audio error propagate into the call flow.
    }
  }
}
