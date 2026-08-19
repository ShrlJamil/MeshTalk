import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../services/audio_route_controller.dart';
import '../services/signaling_service.dart';
import '../theme.dart';

enum CallMode { caller, callee }

class CallScreen extends StatefulWidget {
  const CallScreen({super.key, required this.mode});

  final CallMode mode;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen>
    with SingleTickerProviderStateMixin {
  late final SignalingService _service;
  late final AnimationController _pulseController;
  AudioRouteController? _audioRouteController;
  AudioRoute _audioRoute = AudioRoute.speaker;

  SignalingState _state = SignalingState.idle;
  MediaStream? _remoteStream;

  bool get _isCaller => widget.mode == CallMode.caller;

  @override
  void initState() {
    super.initState();
    _service = SignalingService();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
      lowerBound: 0.6,
      upperBound: 1.2,
    );
    if (_isCaller) {
      _audioRouteController = AudioRouteController()
        ..onRouteChanged = (route) {
          if (mounted) setState(() => _audioRoute = route);
        }..start();
    }
    _start();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _audioRouteController?.dispose();
    unawaited(_service.dispose());
    super.dispose();
  }

  Future<void> _start() async {
    if (_isCaller) {
      await _service.startCaller(
        onRemoteStream: (stream) => setState(() => _remoteStream = stream),
        onStateChanged: _onStateChanged,
      );
    } else {
      await _service.startCallee(
        onRemoteStream: (stream) => setState(() => _remoteStream = stream),
        onStateChanged: _onStateChanged,
      );
    }
  }

  void _onStateChanged(SignalingState state) {
    setState(() => _state = state);
    if (state == SignalingState.connected) {
      _pulseController.repeat(reverse: true);
      _audioRouteController?.refresh();
    } else {
      _pulseController.reset();
    }
  }

  Future<void> _hangup() async {
    await _service.hangup();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  void _toggleAudioRoute() {
    unawaited(_audioRouteController?.toggle());
  }

  Widget _audioRouteButton() {
    final (icon, tooltip, active) = switch (_audioRoute) {
      AudioRoute.speaker => (Icons.volume_up, 'Speaker aktif', true),
      AudioRoute.earpiece => (Icons.phone_in_talk, 'Earpiece aktif', false),
      AudioRoute.headset => (Icons.headset, 'Headset aktif', true),
    };
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: active
            ? [
                BoxShadow(
                  color: kSecondaryColor.withValues(alpha: 0.45),
                  blurRadius: 18,
                  spreadRadius: 2,
                ),
              ]
            : null,
      ),
      child: IconButton(
        onPressed: _toggleAudioRoute,
        icon: Icon(icon),
        color: active ? kSecondaryColor : Colors.white70,
        tooltip: tooltip,
        iconSize: 30,
      ),
    );
  }

  String get _statusLabel {
    switch (_state) {
      case SignalingState.connecting:
        return _isCaller ? 'Menghubungi...' : 'Menunggu Panggilan...';
      case SignalingState.connected:
        return 'Tersambung';
      case SignalingState.disconnected:
        return 'Terputus';
      case SignalingState.failed:
        return 'Gagal Terhubung';
      case SignalingState.idle:
        return _isCaller ? 'Siap' : 'Standby';
    }
  }

  Color get _statusColor {
    switch (_state) {
      case SignalingState.connected:
        return kSecondaryColor;
      case SignalingState.failed:
        return Colors.redAccent;
      case SignalingState.disconnected:
        return Colors.orangeAccent;
      default:
        return Colors.white70;
    }
  }

  Widget _statusIndicator() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ScaleTransition(
          scale: _pulseController,
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: _state == SignalingState.connected
                      ? kSecondaryColor.withValues(alpha: 0.5)
                      : Colors.transparent,
                  blurRadius: 40,
                  spreadRadius: 6,
                ),
              ],
            ),
            child: Icon(
              _state == SignalingState.connected
                  ? Icons.volume_up_rounded
                  : Icons.sync,
              color: _statusColor,
              size: 64,
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          _statusLabel,
          style: TextStyle(
            color: _statusColor,
            fontSize: 24,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _remoteStream != null ? 'Audio tersambung' : 'Interkom Rumah Standby',
          style: const TextStyle(color: Colors.white54, fontSize: 14),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kSurfaceColor,
      body: SafeArea(
        child: Column(
          children: [
            if (!_isCaller)
              Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: IconButton(
                    onPressed: _hangup,
                    icon: const Icon(Icons.power_settings_new),
                    color: kSecondaryColor,
                    tooltip: 'Matikan mode standby',
                  ),
                ),
              ),
            Expanded(child: Center(child: _statusIndicator())),
            if (_isCaller)
              Padding(
                padding: const EdgeInsets.only(bottom: 40),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    FilledButton.icon(
                      onPressed: _hangup,
                      icon: const Icon(Icons.call_end),
                      label: const Text('Akhiri Panggilan'),
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.redAccent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 32,
                          vertical: 16,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _audioRouteButton(),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
