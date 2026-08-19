import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Active audio output route for the Caller side.
enum AudioRoute { speaker, earpiece, headset }

/// Manages audio output routing (Speaker / Earpiece / Headset) and auto-detects
/// wired/Bluetooth headsets via `navigator.mediaDevices.ondevicechange`.
///
/// - Manual toggle switches between Speaker and Earpiece (or Headset when a
///   headset is plugged in).
/// - Plugging a headset automatically routes audio to the Headset; unplugging
///   falls back to the Speaker.
///
/// Switching routes never touches the WebRTC audio constraints, so the noise
/// suppression / echo cancellation configuration stays intact.
class AudioRouteController {
  AudioRoute _route = AudioRoute.speaker;
  AudioRoute get route => _route;

  bool _headsetConnected = false;
  bool get isHeadsetConnected => _headsetConnected;

  void Function(AudioRoute route)? onRouteChanged;

  /// Registers the headset detection listener and performs an initial check.
  void start() {
    navigator.mediaDevices.ondevicechange = (_) {
      refresh();
    };
    refresh();
  }

  /// Re-checks the current audio output devices. Safe to call anytime.
  Future<void> refresh() async {
    final outputs = await Helper.audiooutputs;
    final hasHeadset = outputs.any(
      (d) => d.deviceId == 'bluetooth' || d.deviceId == 'wired-headset',
    );
    if (hasHeadset == _headsetConnected) return;
    _headsetConnected = hasHeadset;
    if (hasHeadset) {
      await _setRoute(AudioRoute.headset);
    } else {
      await _setRoute(AudioRoute.speaker);
    }
  }

  /// User-triggered toggle between routes.
  Future<void> toggle() async {
    if (_headsetConnected) {
      await _setRoute(
        _route == AudioRoute.headset ? AudioRoute.speaker : AudioRoute.headset,
      );
    } else {
      await _setRoute(
        _route == AudioRoute.speaker ? AudioRoute.earpiece : AudioRoute.speaker,
      );
    }
  }

  Future<void> _setRoute(AudioRoute route) async {
    debugPrint('[MeshTalk] audio route: switching to $route');
    switch (route) {
      case AudioRoute.speaker:
        await Helper.setSpeakerphoneOn(true);
      case AudioRoute.earpiece:
        await Helper.setSpeakerphoneOn(false);
      case AudioRoute.headset:
        await _selectHeadsetDevice();
    }
    _route = route;
    onRouteChanged?.call(route);
  }

  Future<void> _selectHeadsetDevice() async {
    final outputs = await Helper.audiooutputs;
    if (outputs.any((d) => d.deviceId == 'bluetooth')) {
      await navigator.mediaDevices
          .selectAudioOutput(AudioOutputOptions(deviceId: 'bluetooth'));
    } else if (outputs.any((d) => d.deviceId == 'wired-headset')) {
      await navigator.mediaDevices
          .selectAudioOutput(AudioOutputOptions(deviceId: 'wired-headset'));
    }
  }

  /// Removes the device-change listener. Call when the call screen is closed.
  void dispose() {
    if (navigator.mediaDevices.ondevicechange != null) {
      navigator.mediaDevices.ondevicechange = null;
    }
  }
}