import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../design/mesh_design.dart';
import '../services/audio_route_controller.dart';
import '../services/signaling_service.dart';
import '../widgets/liquid_glass.dart';

enum CallMode { caller, callee }

/// Active call / standby screen in the solid MeshTalk treatment.
///
/// Visual migration only — every behavior below is unchanged:
/// signaling lifecycle, auto-answer, call timer + 900s cap, hangup and
/// remote-ended handling, mic/route control wiring, announcement send,
/// retry, standby (FGS/WifiLock/heartbeat/presence) via [SignalingService].
class CallScreen extends StatefulWidget {
  const CallScreen({super.key, required this.mode});

  final CallMode mode;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  late final SignalingService _service;
  AudioRouteController? _audioRouteController;
  AudioRoute _audioRoute = AudioRoute.speaker;

  SignalingState _state = SignalingState.idle;
  MediaStream? _remoteStream;

  /// Locks the Hangup/Batal button the instant it's tapped, so a slow
  /// cellular `cleanupRoom()` can never be triggered twice by repeated taps.
  bool _isEnding = false;

  /// Caller-only announcement composer state.
  final TextEditingController _announcementController = TextEditingController();
  bool _sendingAnnouncement = false;

  bool get _isCaller => widget.mode == CallMode.caller;

  /// Remote endpoint name shown in titles.
  String get _remoteName => _isCaller ? 'Callee' : 'Caller';

  @override
  void initState() {
    super.initState();
    _service = SignalingService()
      ..onCallDurationTick = () {
        if (mounted) setState(() {});
      };
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
    _announcementController.dispose();
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
      _audioRouteController?.refresh();
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

  /// Caller-only: sends the typed announcement via
  /// [SignalingService.sendAnnouncement] (Firebase write only), then clears
  /// the input and shows a short confirmation.
  Future<void> _sendAnnouncement() async {
    final text = _announcementController.text.trim();
    if (text.isEmpty || _sendingAnnouncement) return;
    setState(() => _sendingAnnouncement = true);
    final sent = await _service.sendAnnouncement(text);
    if (!mounted) return;
    setState(() => _sendingAnnouncement = false);
    final messenger = ScaffoldMessenger.of(context);
    if (sent) {
      _announcementController.clear();
      messenger.showSnackBar(
        const SnackBar(content: Text('Announcement sent')),
      );
    } else {
      messenger.showSnackBar(
        const SnackBar(content: Text('Failed to send announcement')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isConnected = _state == SignalingState.connected;

    return Scaffold(
      backgroundColor: MeshSurface.background,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints:
                const BoxConstraints(maxWidth: MeshSize.maxContentWidth),
            child: Column(
              children: [
                // Top application area — same language as HomeScreen.
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    MeshSize.screenMargin,
                    MeshSpace.lg,
                    MeshSize.screenMargin,
                    MeshSpace.sm,
                  ),
                  child: _Header(isCaller: _isCaller),
                ),
                const Divider(
                  height: 1,
                  thickness: 1,
                  color: MeshNeutral.border,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    MeshSize.screenMargin,
                    MeshSpace.md,
                    MeshSize.screenMargin,
                    0,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: DynamicLivePill(
                      state: _state,
                      formattedDuration: _service.formattedCallDuration,
                      idleLabel: _isCaller ? 'Callee' : 'Standby',
                    ),
                  ),
                ),
                Expanded(
                  // Scrolls instead of overflowing when the soft keyboard
                  // shrinks this area for the announcement composer.
                  child: LayoutBuilder(
                    builder: (context, constraints) =>
                        SingleChildScrollView(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                            minHeight: constraints.maxHeight),
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: MeshSize.screenMargin),
                            child: _StateBody(
                              state: _state,
                              isCaller: _isCaller,
                              remoteName: _remoteName,
                              hasAudio: _remoteStream != null,
                              formattedDuration:
                                  _service.formattedCallDuration,
                              isMicMuted: _service.isMicMuted,
                              audioRoute: _audioRoute,
                              onToggleMic: _toggleMic,
                              onToggleRoute: _toggleAudioRoute,
                              onRetry: _retry,
                              onBack: _hangup,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    MeshSize.screenMargin,
                    MeshSpace.md,
                    MeshSize.screenMargin,
                    MeshSpace.xl,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_isCaller &&
                          (isConnected ||
                              _state == SignalingState.connecting))
                        _AnnouncementComposer(
                          controller: _announcementController,
                          sending: _sendingAnnouncement,
                          onChanged: (_) => setState(() {}),
                          onSend: _sendAnnouncement,
                        ),
                      if (_isCaller &&
                          (isConnected ||
                              _state == SignalingState.connecting))
                        const SizedBox(height: MeshSpace.md),
                      _BottomControls(
                        state: _state,
                        isCaller: _isCaller,
                        isEnding: _isEnding,
                        onHangup: _hangup,
                        onRetry: _retry,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Top bar: MeshTalk wordmark + static role indicator.
///
/// The indicator mirrors HomeScreen's selector visually but is
/// deliberately non-interactive — CallScreen's lifecycle does not support
/// switching roles mid-screen.
class _Header extends StatelessWidget {
  const _Header({required this.isCaller});

  final bool isCaller;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _Bar(height: 10, color: MeshBrand.primaryAction),
            SizedBox(width: 2),
            _Bar(height: 15, color: MeshLive.connected),
            SizedBox(width: 2),
            _Bar(height: 8, color: MeshNeutral.icon),
            SizedBox(width: 8),
            Text(
              'MeshTalk',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: MeshNeutral.textPrimary,
              ),
            ),
          ],
        ),
        const Spacer(),
        IgnorePointer(
          child: Container(
            padding: const EdgeInsets.all(MeshSpace.xs),
            decoration: BoxDecoration(
              color: MeshSurface.surface,
              borderRadius: BorderRadius.circular(MeshRadius.sm),
              border: Border.all(color: MeshNeutral.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _RoleLabel(label: MeshTerms.caller, active: isCaller),
                _RoleLabel(label: MeshTerms.callee, active: !isCaller),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.height, required this.color});

  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 4,
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(1),
      ),
    );
  }
}

class _RoleLabel extends StatelessWidget {
  const _RoleLabel({required this.label, required this.active});

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: MeshSpace.md,
        vertical: MeshSpace.sm,
      ),
      decoration: BoxDecoration(
        color: active ? MeshSurface.control : Colors.transparent,
        borderRadius: BorderRadius.circular(MeshRadius.sm - 2),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color:
              active ? MeshNeutral.textPrimary : MeshNeutral.textSecondary,
        ),
      ),
    );
  }
}

/// Center-stage content per call state. Pure presentation over [_state] —
/// no signaling, no new states.
class _StateBody extends StatelessWidget {
  const _StateBody({
    required this.state,
    required this.isCaller,
    required this.remoteName,
    required this.hasAudio,
    required this.formattedDuration,
    required this.isMicMuted,
    required this.audioRoute,
    required this.onToggleMic,
    required this.onToggleRoute,
    required this.onRetry,
    required this.onBack,
  });

  final SignalingState state;
  final bool isCaller;
  final String remoteName;
  final bool hasAudio;
  final String formattedDuration;
  final bool isMicMuted;
  final AudioRoute audioRoute;
  final VoidCallback onToggleMic;
  final VoidCallback onToggleRoute;
  final VoidCallback onRetry;
  final VoidCallback onBack;

  String get _eyebrow => isCaller ? 'Outgoing intercom' : 'Callee intercom';

  @override
  Widget build(BuildContext context) {
    return switch (state) {
      SignalingState.connected => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_eyebrow, style: MeshText.eyebrow),
            const SizedBox(height: MeshSpace.sm),
            Text(remoteName, style: MeshText.pageTitle),
            const SizedBox(height: MeshSpace.sm),
            Text(
              formattedDuration,
              style: MeshText.timer(),
            ),
            if (hasAudio) ...[
              const SizedBox(height: MeshSpace.xs),
              const Text('Audio connected', style: MeshText.metadata),
            ],
            const SizedBox(height: MeshSpace.xl),
            _AudioRouteCard(
              route: audioRoute,
              interactive: isCaller,
              onTap: onToggleRoute,
            ),
            const SizedBox(height: MeshSpace.sm),
            _MicRow(muted: isMicMuted, onTap: onToggleMic),
          ],
        ),
      SignalingState.connecting when isCaller => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_eyebrow, style: MeshText.eyebrow),
            const SizedBox(height: MeshSpace.sm),
            const Text('Calling Callee', style: MeshText.pageTitle),
            const SizedBox(height: MeshSpace.sm),
            const Text(
              'Establishing connection…',
              style: MeshText.supporting,
            ),
            const SizedBox(height: MeshSpace.xl),
            const SizedBox(
              width: 120,
              child: LinearProgressIndicator(
                minHeight: 2,
                backgroundColor: MeshSurface.surfaceElevated,
                valueColor:
                    AlwaysStoppedAnimation<Color>(MeshLive.connected),
              ),
            ),
          ],
        ),
      SignalingState.connecting => Column(
          // Callee standby: waiting for (and auto-answering) offers.
          // `connecting` covers both waiting and answering — one honest
          // treatment, no Decline, no invented incoming state.
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(
              Icons.smartphone_rounded,
              size: 40,
              color: MeshNeutral.iconMuted,
            ),
            SizedBox(height: MeshSpace.xl),
            Text(
              'Callee is ready.',
              style: MeshText.pageTitle,
              textAlign: TextAlign.center,
            ),
            SizedBox(height: MeshSpace.sm),
            Text(
              'Keep this device powered and nearby. '
              'Incoming calls will answer automatically.',
              style: MeshText.supporting,
              textAlign: TextAlign.center,
            ),
            SizedBox(height: MeshSpace.xl),
            _StandbyInfoCard(),
          ],
        ),
      SignalingState.failed => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '!',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: MeshAlert.dangerText,
                height: 1,
              ),
            ),
            const SizedBox(height: MeshSpace.md),
            Text(_eyebrow, style: MeshText.eyebrow),
            const SizedBox(height: MeshSpace.sm),
            const Text('Connection failed', style: MeshText.pageTitle),
            const SizedBox(height: MeshSpace.sm),
            Text(
              isCaller
                  ? 'Could not connect to Callee.'
                  : 'Could not establish the call.',
              style: MeshText.supporting,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: MeshSpace.xl),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: FilledButton(
                    style: MeshControls.primaryAction(),
                    onPressed: onRetry,
                    child: const Text('Try again'),
                  ),
                ),
                const SizedBox(width: MeshSpace.md),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    style: MeshControls.secondary(),
                    // Same path as hangup: service cleanup, then pop.
                    onPressed: onBack,
                    child: const Text('Back'),
                  ),
                ),
              ],
            ),
          ],
        ),
      SignalingState.disconnected => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_eyebrow, style: MeshText.eyebrow),
            const SizedBox(height: MeshSpace.sm),
            const Text('Connection lost', style: MeshText.pageTitle),
            const SizedBox(height: MeshSpace.sm),
            const Text(
              'The call was interrupted.',
              style: MeshText.supporting,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      SignalingState.idle => const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Preparing…', style: MeshText.pageTitle),
          ],
        ),
    };
  }
}

/// Static standby facts. Only claims what the existing flow guarantees:
/// speaker forced on after handshake, auto-answer always on.
class _StandbyInfoCard extends StatelessWidget {
  const _StandbyInfoCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(MeshSpace.lg),
      decoration: BoxDecoration(
        color: MeshSurface.surfaceElevated,
        borderRadius: BorderRadius.circular(MeshRadius.md),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Ready to receive calls', style: MeshText.section),
          SizedBox(height: MeshSpace.xs),
          Text(
            'Speaker on · Auto-answer on',
            style: MeshText.metadata,
          ),
        ],
      ),
    );
  }
}

/// Audio-output row. Tappable for the Caller (existing toggle); static
/// for the Callee (route fixed to speaker by the existing flow).
class _AudioRouteCard extends StatelessWidget {
  const _AudioRouteCard({
    required this.route,
    required this.interactive,
    required this.onTap,
  });

  final AudioRoute route;
  final bool interactive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (icon, label) = switch (route) {
      AudioRoute.speaker => (Icons.volume_up_rounded, 'Speaker'),
      AudioRoute.earpiece => (Icons.phone_in_talk_rounded, 'Earpiece'),
      AudioRoute.headset => (Icons.headset_rounded, 'Headset'),
    };
    final row = Container(
      padding: const EdgeInsets.symmetric(
        horizontal: MeshSpace.lg,
        vertical: MeshSpace.md,
      ),
      decoration: BoxDecoration(
        color: MeshSurface.surfaceElevated,
        borderRadius: BorderRadius.circular(MeshRadius.md),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.speaker_rounded,
            size: 22,
            color: MeshNeutral.iconMuted,
          ),
          const SizedBox(width: MeshSpace.md),
          const Expanded(
            child: Text('Audio route', style: MeshText.metadata),
          ),
          Icon(icon, size: 18, color: MeshNeutral.icon),
          const SizedBox(width: MeshSpace.xs),
          Text(label, style: MeshText.section.copyWith(fontSize: 13)),
          if (interactive) ...[
            const SizedBox(width: MeshSpace.xs),
            const Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: MeshNeutral.iconMuted,
            ),
          ],
        ],
      ),
    );
    if (!interactive) return row;
    return InkWell(
      borderRadius: BorderRadius.circular(MeshRadius.md),
      onTap: onTap,
      child: row,
    );
  }
}

/// Microphone state with a full 48px tap target. Toggles the existing
/// mute — no new mute system.
class _MicRow extends StatelessWidget {
  const _MicRow({required this.muted, required this.onTap});

  final bool muted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(MeshRadius.sm),
      onTap: onTap,
      child: SizedBox(
        height: MeshSize.iconButton,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              muted ? Icons.mic_off_rounded : Icons.mic_rounded,
              size: 20,
              color:
                  muted ? MeshAlert.dangerText : MeshNeutral.iconMuted,
            ),
            const SizedBox(width: MeshSpace.sm),
            Text(
              muted ? 'Microphone off' : 'Microphone on',
              style: MeshText.metadata.copyWith(
                color: muted
                    ? MeshAlert.dangerText
                    : MeshNeutral.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Caller-only announcement composer (solid treatment). Same send flow,
/// same length cap, same confirmations.
class _AnnouncementComposer extends StatelessWidget {
  const _AnnouncementComposer({
    required this.controller,
    required this.sending,
    required this.onChanged,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool sending;
  final ValueChanged<String> onChanged;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final canSend = controller.text.trim().isNotEmpty && !sending;
    return ConstrainedBox(
      constraints:
          const BoxConstraints(maxWidth: MeshSize.maxContentWidth),
      child: Container(
        padding: const EdgeInsets.fromLTRB(
            MeshSpace.lg, MeshSpace.xs, MeshSpace.xs, MeshSpace.xs),
        decoration: BoxDecoration(
          color: MeshSurface.surfaceElevated,
          borderRadius: BorderRadius.circular(MeshRadius.md),
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 3,
                maxLength: SignalingService.maxAnnouncementLength,
                textInputAction: TextInputAction.send,
                onChanged: onChanged,
                onSubmitted: (_) => onSend(),
                cursorColor: MeshLive.connected,
                style: MeshText.body,
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  counterText: '',
                  hintText: 'Announce to callee…',
                  hintStyle: MeshText.supporting,
                ),
              ),
            ),
            const SizedBox(width: MeshSpace.xs),
            SizedBox(
              width: MeshSize.iconButton,
              height: MeshSize.iconButton,
              child: IconButton(
                tooltip: 'Send announcement',
                onPressed: canSend ? onSend : null,
                icon: Icon(
                  Icons.campaign_rounded,
                  size: 22,
                  color: canSend
                      ? MeshBrand.primaryAction
                      : MeshNeutral.textFaint,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bottom action area per state. Hangup path untouched: [_hangup] locks,
/// cleans up in background, pops.
class _BottomControls extends StatelessWidget {
  const _BottomControls({
    required this.state,
    required this.isCaller,
    required this.isEnding,
    required this.onHangup,
    required this.onRetry,
  });

  final SignalingState state;
  final bool isCaller;
  final bool isEnding;
  final VoidCallback onHangup;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    // Failed already offers Try again + Back (Back == hangup path).
    if (state == SignalingState.failed) return const SizedBox.shrink();
    final label = switch (state) {
      SignalingState.connected => 'End call',
      SignalingState.connecting =>
        isCaller ? 'End call' : 'Leave standby',
      SignalingState.disconnected => 'End call',
      SignalingState.idle => 'End call',
      SignalingState.failed => 'End call',
    };
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        style: MeshControls.danger(),
        // Locked instantly once tapped — see _hangup().
        onPressed: isEnding ? null : onHangup,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.call_end_rounded,
              size: 22,
              color: Colors.white,
            ),
            const SizedBox(width: MeshSpace.sm),
            Text(label, style: MeshText.action),
          ],
        ),
      ),
    );
  }
}
