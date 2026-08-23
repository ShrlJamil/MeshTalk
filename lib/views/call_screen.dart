import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../services/audio_route_controller.dart';
import '../services/signaling_service.dart';
import '../theme.dart';
import '../widgets/liquid_glass.dart';

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

  /// Locks the Hangup/Batal button the instant it's tapped, so a slow
  /// cellular `cleanupRoom()` can never be triggered twice by repeated taps.
  bool _isEnding = false;

  bool get _isCaller => widget.mode == CallMode.caller;

  @override
  void initState() {
    super.initState();
    _service = SignalingService()
      ..onCallDurationTick = () {
        if (mounted) setState(() {});
      };
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
        onRemoteStream: _onRemoteStream,
        onStateChanged: _onStateChanged,
      );
    } else {
      await _service.startCallee(
        onRemoteStream: _onRemoteStream,
        onStateChanged: _onStateChanged,
      );
    }
  }

  /// Re-attempts the same mode after a failed handshake. Reuses `_start()`
  /// (and therefore `cleanupRoom()`'s own re-entrancy guard), so this is
  /// safe even if pressed right as some other cleanup is still settling.
  Future<void> _retry() async {
    if (_isEnding || _state != SignalingState.failed) return;
    setState(() => _state = SignalingState.connecting);
    await _start();
  }

  void _onRemoteStream(MediaStream stream) {
    // The service keeps running in the background after _hangup() pops this
    // screen (see below), so a late callback landing on a disposed State
    // must never call setState.
    if (!mounted) return;
    setState(() => _remoteStream = stream);
  }

  void _onStateChanged(SignalingState state) {
    if (!mounted) return;
    setState(() => _state = state);
    if (state == SignalingState.connected) {
      _pulseController.repeat(reverse: true);
      _audioRouteController?.refresh();
    } else {
      _pulseController.reset();
    }
  }

  Future<void> _hangup() async {
    if (_isEnding) return;
    // Instant feedback: lock the button and drop straight to the idle
    // visual before anything async happens, so a slow cellular
    // cleanupRoom() can never be triggered a second time by another tap.
    setState(() {
      _isEnding = true;
      _state = SignalingState.idle;
    });
    // Runs in the background — cleanupRoom() keeps going even after this
    // screen is popped below; SignalingService itself now guards against
    // re-entrant cleanup, and the callbacks above are mounted-guarded.
    unawaited(_service.hangup());
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  void _toggleMic() {
    setState(() => _service.toggleMic());
  }

  void _toggleAudioRoute() {
    unawaited(_audioRouteController?.toggle());
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

  Color _statusColor(MeshGlassPalette palette) {
    switch (_state) {
      case SignalingState.connected:
        return kAccentColor;
      case SignalingState.failed:
        return kDangerColor;
      case SignalingState.disconnected:
        return Colors.orangeAccent;
      default:
        return palette.textSecondary;
    }
  }

  IconData get _statusIcon {
    if (_state == SignalingState.connected) return Icons.volume_up_rounded;
    return _isCaller ? Icons.call_rounded : Icons.headset_mic_rounded;
  }

  /// The two large symmetric mode icons. Only the button matching this
  /// screen's actual mode is ever interactive (as a retry, and only once
  /// the handshake has failed) — the other is shown dimmed purely so the
  /// pair reads as a deliberate, balanced pair rather than a missing button.
  Widget _modeButtonsRow() {
    final canRetry = _state == SignalingState.failed;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Opacity(
          opacity: _isCaller ? 0.35 : 1,
          child: GlassCircleButton(
            icon: Icons.headset_mic_rounded,
            label: 'Standby',
            tooltip: 'Aktifkan Standby',
            tint: kStandbyAccentColor,
            onPressed: (!_isCaller && canRetry) ? _retry : null,
          ),
        ),
        const SizedBox(width: 28),
        Opacity(
          opacity: _isCaller ? 1 : 0.35,
          child: GlassCircleButton(
            icon: Icons.call_rounded,
            label: 'Call',
            tooltip: 'Mulai Panggilan',
            tint: kCallAccentColor,
            onPressed: (_isCaller && canRetry) ? _retry : null,
          ),
        ),
      ],
    );
  }

  Widget _controlDock(bool isConnected) {
    final isMuted = _service.isMicMuted;
    final (audioIcon, audioTooltip) = switch (_audioRoute) {
      AudioRoute.speaker => (Icons.volume_up_rounded, 'Speaker aktif — ketuk untuk earpiece'),
      AudioRoute.earpiece => (Icons.phone_in_talk_rounded, 'Earpiece aktif — ketuk untuk speaker'),
      AudioRoute.headset => (Icons.headset_rounded, 'Headset aktif'),
    };
    return GlassDock(
      children: [
        GlassDockButton(
          icon: isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
          tooltip: isMuted ? 'Nyalakan mic' : 'Matikan mic',
          active: isMuted,
          tint: isMuted ? kDangerColor : null,
          onPressed: _toggleMic,
        ),
        const SizedBox(width: 20),
        GlassDockButton(
          icon: Icons.call_end_rounded,
          tooltip: isConnected
              ? 'Akhiri panggilan'
              : (_isCaller ? 'Batalkan panggilan' : 'Matikan mode standby'),
          diameter: 64,
          iconSize: 30,
          tint: kDangerColor,
          // Locked instantly once tapped — see _hangup().
          onPressed: _isEnding ? null : _hangup,
        ),
        const SizedBox(width: 20),
        GlassDockButton(
          icon: audioIcon,
          tooltip: audioTooltip,
          active: _audioRoute != AudioRoute.earpiece,
          // Route switching is caller-only: AudioRouteController is never
          // started for the Callee (see initState) since its output route
          // is fixed to speaker right after handshake, not user-toggleable.
          onPressed: _isCaller ? _toggleAudioRoute : null,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = glassPaletteFor(Theme.of(context).brightness);
    final statusColor = _statusColor(palette);
    final isConnected = _state == SignalingState.connected;

    return Scaffold(
      backgroundColor: palette.background,
      body: Stack(
        children: [
          const Positioned.fill(child: GlassBackdrop()),
          SafeArea(
            child: Column(
              children: [
                GlassAppBar(
                  title: 'MeshTalk',
                  center: DynamicLivePill(
                    state: _state,
                    formattedDuration: _service.formattedCallDuration,
                    idleLabel: 'Target',
                  ),
                ),
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ScaleTransition(
                          scale: _pulseController,
                          child: Container(
                            width: 140,
                            height: 140,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: palette.cardFill,
                              border: Border.all(color: palette.cardBorder, width: 1.5),
                              boxShadow: [
                                BoxShadow(
                                  color: statusColor.withValues(
                                    alpha: isConnected ? 0.5 : 0.15,
                                  ),
                                  blurRadius: 40,
                                  spreadRadius: 6,
                                ),
                              ],
                            ),
                            child: Icon(_statusIcon, size: 56, color: statusColor),
                          ),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          _statusLabel,
                          style: TextStyle(
                            color: statusColor,
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _remoteStream != null ? 'Audio tersambung' : 'Interkom Standby',
                          style: TextStyle(color: palette.textSecondary, fontSize: 13),
                        ),
                        const SizedBox(height: 28),
                        // Call duration now lives solely in DynamicLivePill
                        // (in GlassAppBar) — no redundant big timer here.
                        // Center stage stays focused on the status icon/text
                        // above once connected; the mode buttons only show
                        // pre-connection (and as a failed-state retry).
                        if (!isConnected) _modeButtonsRow(),
                      ],
                    ),
                  ),
                ),
                // Reserve space so the floating dock never overlaps content
                // scrolled to the bottom of the Column above.
                const SizedBox(height: 116),
              ],
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 24),
                child: Center(child: _controlDock(isConnected)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
