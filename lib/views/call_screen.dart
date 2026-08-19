import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../services/signaling_service.dart';

enum CallMode { caller, callee }

class CallScreen extends StatefulWidget {
  const CallScreen({super.key, required this.mode});

  final CallMode mode;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  late final SignalingService _service;

  SignalingState _state = SignalingState.idle;
  MediaStream? _remoteStream;

  bool get _isCaller => widget.mode == CallMode.caller;

  @override
  void initState() {
    super.initState();
    _service = SignalingService();
    _start();
  }

  Future<void> _start() async {
    if (_isCaller) {
      await _service.startCaller(
        onRemoteStream: (stream) => setState(() => _remoteStream = stream),
        onStateChanged: (state) => setState(() => _state = state),
      );
    } else {
      await _service.startCallee(
        onRemoteStream: (stream) => setState(() => _remoteStream = stream),
        onStateChanged: (state) => setState(() => _state = state),
      );
    }
  }

  Future<void> _hangup() async {
    await _service.hangup();
    if (!mounted) return;
    Navigator.of(context).pop();
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
        return Colors.greenAccent;
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
        Icon(
          _state == SignalingState.connected
              ? Icons.volume_up_rounded
              : Icons.sync,
          color: _statusColor,
          size: 64,
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
      backgroundColor: Colors.black,
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
                    color: Colors.white70,
                    tooltip: 'Matikan mode standby',
                  ),
                ),
              ),
            Expanded(child: Center(child: _statusIndicator())),
            if (_isCaller)
              Padding(
                padding: const EdgeInsets.only(bottom: 40),
                child: FilledButton.icon(
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
              ),
          ],
        ),
      ),
    );
  }
}
