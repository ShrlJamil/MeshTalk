import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../design/mesh_design.dart';
import '../services/signaling_service.dart';
import '../widgets/callee_status_pill.dart';
import 'call_screen.dart';

/// Home: role selection (Caller | Callee), Callee status pill, explicit
/// `Call Callee` action and the announcement entry point.
///
/// Behavior is unchanged from the glass era:
/// - The role selector only switches local UI. It never starts anything.
/// - Caller presses `Call Callee` explicitly ([_enterMode] with
///   [CallMode.caller]); nothing auto-dials.
/// - Callee presses `Start Standby` explicitly ([_enterMode] with
///   [CallMode.callee]), which runs the existing `startCallee()` flow
///   (auto-answer, presence, foreground service) inside [CallScreen].
/// - Status uses the on-demand `callee_status_request` / `callee_status`
///   pair ([requestCalleeStatus]); no telemetry, no new signaling state.
/// - Announcement is the same RTDB write + Worker wake
///   ([publishAnnouncement]); only the entry row was restyled.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

enum _HomeRole { caller, callee }

class _HomeScreenState extends State<HomeScreen> {
  _HomeRole _role = _HomeRole.caller;

  Future<void> _enterMode(CallMode mode) async {
    var status = await Permission.microphone.request();
    if (status.isPermanentlyDenied) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'Izin mikrofon diblokir permanen. Buka pengaturan untuk mengizinkan akses mikrofon.',
          ),
          action: SnackBarAction(
            label: 'Buka Pengaturan',
            onPressed: openAppSettings,
          ),
        ),
      );
      return;
    }

    if (!status.isGranted) {
      status = await Permission.microphone.request();
    }

    if (!status.isGranted) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Izin mikrofon dibutuhkan untuk menggunakan interkom.'),
        ),
      );
      return;
    }

    // Standby keeps a Firebase listener alive in the background waiting for
    // an incoming offer — without a battery-optimization exemption, Android
    // (and especially MIUI/Realme UI) can freeze that listener within
    // minutes. `.status` already makes this effectively "ask once": once
    // granted, every future Standby entry is a no-op check.
    if (mode == CallMode.callee) {
      if (!mounted) return;
      await _requestBatteryOptimizationExemption();
      // On Android 13+, POST_NOTIFICATIONS is a runtime permission — without
      // it, neither the Standby foreground-service notification nor the
      // dedicated incoming-call notification (IncomingCallNotificationController)
      // can actually display. `.request()` is a no-op if already granted.
      await Permission.notification.request();
    }

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => CallScreen(mode: mode)),
    );
  }

  /// Lets the Caller broadcast a spoken announcement to the Callee WITHOUT
  /// starting a call. Just an RTDB write + Worker standby-wake (see
  /// [publishAnnouncement]) — no mic permission, no WebRTC, no CallScreen.
  Future<void> _promptAnnouncement() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Announcement'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: SignalingService.maxAnnouncementLength,
          minLines: 1,
          maxLines: 3,
          textInputAction: TextInputAction.send,
          decoration: const InputDecoration(
            hintText: 'e.g. Dinner is ready',
          ),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmed = text?.trim() ?? '';
    if (trimmed.isEmpty || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await publishAnnouncement(trimmed);
    messenger.showSnackBar(
      SnackBar(
        content: Text(ok ? 'Announcement sent' : 'Failed to send announcement'),
      ),
    );
  }

  Future<void> _requestBatteryOptimizationExemption() async {
    final status = await Permission.ignoreBatteryOptimizations.status;
    if (status.isGranted) return;

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Agar panggilan masuk tetap diterima saat layar mati, izinkan '
          'MeshTalk berjalan tanpa optimasi baterai.',
        ),
        duration: Duration(seconds: 4),
      ),
    );
    await Permission.ignoreBatteryOptimizations.request();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MeshSurface.background,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints:
                const BoxConstraints(maxWidth: MeshSize.maxContentWidth),
            child: Column(
              children: [
                // Top application area: brand + role selector. Pinned —
                // it never scrolls with the content below.
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    MeshSize.screenMargin,
                    MeshSpace.lg,
                    MeshSize.screenMargin,
                    MeshSpace.sm,
                  ),
                  child: _Header(
                    role: _role,
                    onRole: (role) => setState(() => _role = role),
                  ),
                ),
                const Divider(
                  height: 1,
                  thickness: 1,
                  color: MeshNeutral.border,
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(
                      MeshSize.screenMargin,
                      MeshSpace.lg,
                      MeshSize.screenMargin,
                      MeshSpace.xxl,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_role == _HomeRole.caller) ...[
                          const Align(
                            alignment: Alignment.centerLeft,
                            child: CalleeStatusPill(),
                          ),
                          const SizedBox(height: MeshSpace.xl),
                          _CallerPane(
                            onCall: () => _enterMode(CallMode.caller),
                            onAnnounce: _promptAnnouncement,
                          ),
                        ] else
                          _CalleePane(
                            onStartStandby: () =>
                                _enterMode(CallMode.callee),
                          ),
                      ],
                    ),
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

/// Top bar: MeshTalk wordmark + Caller|Callee role selector.
///
/// The selector is a pure UI switch — selecting a role navigates nowhere
/// and starts nothing. Explicit action buttons below do that.
class _Header extends StatelessWidget {
  const _Header({required this.role, required this.onRole});

  final _HomeRole role;
  final ValueChanged<_HomeRole> onRole;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const _Wordmark(),
        const Spacer(),
        Container(
          padding: const EdgeInsets.all(MeshSpace.xs),
          decoration: BoxDecoration(
            color: MeshSurface.surface,
            borderRadius: BorderRadius.circular(MeshRadius.sm),
            border: Border.all(color: MeshNeutral.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _RoleSegment(
                label: MeshTerms.caller,
                selected: role == _HomeRole.caller,
                onTap: () => onRole(_HomeRole.caller),
              ),
              _RoleSegment(
                label: MeshTerms.callee,
                selected: role == _HomeRole.callee,
                onTap: () => onRole(_HomeRole.callee),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Wordmark extends StatelessWidget {
  const _Wordmark();

  @override
  Widget build(BuildContext context) {
    return const Row(
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

class _RoleSegment extends StatelessWidget {
  const _RoleSegment({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: MeshSpace.md,
          vertical: MeshSpace.sm,
        ),
        decoration: BoxDecoration(
          color: selected ? MeshSurface.control : Colors.transparent,
          borderRadius: BorderRadius.circular(MeshRadius.sm - 2),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: selected
                ? MeshNeutral.textPrimary
                : MeshNeutral.textSecondary,
          ),
        ),
      ),
    );
  }
}

/// Caller role: presence-driven headline, explicit `Call Callee` action,
/// announcement entry.
///
/// The presence stream here only drives headline copy. `offline` is
/// informational — the call action stays enabled in every state because
/// the call flow itself handles wake-up/reconnect.
class _CallerPane extends StatelessWidget {
  const _CallerPane({required this.onCall, required this.onAnnounce});

  final VoidCallback onCall;
  final VoidCallback onAnnounce;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DatabaseEvent>(
      stream: FirebaseDatabase.instance
          .ref('${SignalingService.roomPath}/presence/status')
          .onValue,
      builder: (context, snapshot) {
        final (headline, sub) = switch (snapshot.data?.snapshot.value) {
          'ready' => (
              'Ready when you are.',
              'Callee will answer automatically.'
            ),
          'offline' => (
              'Callee is offline.',
              'Call Callee will attempt to wake it.'
            ),
          'waking' => (
              'Waking callee…',
              'Establishing the standby link.'
            ),
          'in_call' => (
              'Callee in call.',
              'This callee is busy right now.'
            ),
          _ => (
              'Checking callee…',
              'Waiting for callee presence.'
            ),
        };
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Intercom', style: MeshText.eyebrow),
            const SizedBox(height: MeshSpace.sm),
            Text(headline, style: MeshText.pageTitle),
            const SizedBox(height: MeshSpace.sm),
            Text(sub, style: MeshText.supporting),
            const SizedBox(height: MeshSpace.xl),
            _CallAction(onCall: onCall),
            const SizedBox(height: MeshSpace.md),
            _AnnouncementRow(onTap: onAnnounce),
          ],
        );
      },
    );
  }
}

/// Primary call action. Always enabled with the same solid-purple
/// treatment in every presence state — including offline. Pressing it is
/// the ONLY way to start a caller flow from Home; wake-up/reconnect is
/// the call flow's own responsibility, not this button's.
class _CallAction extends StatelessWidget {
  const _CallAction({required this.onCall});

  final VoidCallback onCall;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        style: MeshControls.primaryAction(),
        onPressed: onCall,
        child: Row(
          children: [
            const Icon(
              Icons.call_rounded,
              size: 22,
              color: Colors.white,
            ),
            const SizedBox(width: MeshSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    MeshTerms.callCallee,
                    style: MeshText.action,
                  ),
                  Text(
                    'Hands-free voice call',
                    style: MeshText.metadata.copyWith(color: Colors.white70),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.arrow_forward_rounded,
              size: 20,
              color: Colors.white70,
            ),
          ],
        ),
      ),
    );
  }
}

/// Secondary announcement entry. Same dialog + RTDB + Worker flow as
/// before — only this row was restyled.
class _AnnouncementRow extends StatelessWidget {
  const _AnnouncementRow({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(MeshRadius.md),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(MeshSpace.lg),
        decoration: BoxDecoration(
          color: MeshSurface.surfaceElevated,
          borderRadius: BorderRadius.circular(MeshRadius.md),
        ),
        child: const Row(
          children: [
            Icon(
              Icons.campaign_outlined,
              size: 22,
              color: MeshNeutral.iconMuted,
            ),
            SizedBox(width: MeshSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(MeshTerms.announcement, style: MeshText.section),
                  SizedBox(height: 2),
                  Text(
                    'Speak a message at Callee',
                    style: MeshText.metadata,
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: MeshNeutral.iconMuted,
            ),
          ],
        ),
      ),
    );
  }
}

/// Callee role: concise standby explainer. Entering standby still requires
/// an explicit press, which runs the existing `startCallee()` flow via
/// [_enterMode] — no new state, no new signaling.
class _CalleePane extends StatelessWidget {
  const _CalleePane({required this.onStartStandby});

  final VoidCallback onStartStandby;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const SizedBox(height: MeshSpace.xxl),
        const Icon(
          Icons.smartphone_rounded,
          size: 40,
          color: MeshNeutral.iconMuted,
        ),
        const SizedBox(height: MeshSpace.xl),
        const Text(
          'Callee is ready.',
          style: MeshText.pageTitle,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: MeshSpace.sm),
        const Text(
          'Keep this device powered and nearby. '
          'Incoming calls will answer automatically.',
          style: MeshText.supporting,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: MeshSpace.xxl),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            style: MeshControls.primaryAction(),
            onPressed: onStartStandby,
            child: const Text('Start Standby'),
          ),
        ),
      ],
    );
  }
}
