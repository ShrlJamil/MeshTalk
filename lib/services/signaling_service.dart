import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'foreground_service_controller.dart';
import 'hangup_tone_player.dart';
import 'notice_tone_player.dart';
import 'proximity_screen_controller.dart';
import 'screen_wake_controller.dart';

enum SignalingState {
  idle,
  connecting,
  connected,
  disconnected,
  failed,
}

class SignalingService with WidgetsBindingObserver {
  SignalingService({DatabaseReference? database})
      : _database = database ?? FirebaseDatabase.instance.ref() {
    WidgetsBinding.instance.addObserver(this);
  }

  static const String roomPath = 'intercom_rooms/rumah_utama';

  /// Built from `.env` (TURN_USERNAME / TURN_CREDENTIAL) on every access
  /// rather than as a compile-time const, since the credentials are only
  /// known once `dotenv.load()` has run at app startup. Never logged.
  static Map<String, dynamic> get _iceConfiguration {
    final username = dotenv.env['TURN_USERNAME'];
    final credential = dotenv.env['TURN_CREDENTIAL'];
    if (username == null || username.isEmpty || credential == null || credential.isEmpty) {
      throw StateError(
        'Missing TURN_USERNAME/TURN_CREDENTIAL in .env. '
        'Ensure dotenv.load() has run and .env defines both keys before '
        'starting a call.',
      );
    }
    return {
      'iceServers': [
        {
          'urls': 'stun:stun.relay.metered.ca:80',
        },
        {
          'urls': 'turn:global.relay.metered.ca:80',
          'username': username,
          'credential': credential,
        },
        {
          'urls': 'turn:global.relay.metered.ca:80?transport=tcp',
          'username': username,
          'credential': credential,
        },
        {
          'urls': 'turn:global.relay.metered.ca:443',
          'username': username,
          'credential': credential,
        },
        {
          'urls': 'turns:global.relay.metered.ca:443?transport=tcp',
          'username': username,
          'credential': credential,
        },
      ],
    };
  }

  /// Audio constraints for WebRTC's software APM (echo cancellation, noise
  /// suppression, high-pass filter). `autoGainControl` is deliberately OFF:
  /// `MODE_IN_COMMUNICATION` (see `_configureVoipAudio`) already activates
  /// each chipset's own hardware voice-processing HAL, and stacking WebRTC's
  /// software AGC on top of an aggressive hardware AGC (observed on
  /// Snapdragon/Poco) over-compresses and distorts the vocal signal. The
  /// legacy/secondary echo-cancellation variants (`googEchoCancellation2`,
  /// `googDAEchoCancellation`) are dropped for the same reason: they select
  /// extra proprietary processing paths on top of the standard AEC, which
  /// only made hardware-dependent behavior less consistent between Qualcomm
  /// and MediaTek chipsets. `mandatory` alone is exhaustive — Android and
  /// iOS both skip their constraint defaults once a Map is provided, so no
  /// `optional` duplication is needed.
  static const Map<String, dynamic> _audioConstraints = {
    'mandatory': {
      'echoCancellation': true,
      'googEchoCancellation': true,
      'noiseSuppression': true,
      'googNoiseSuppression': true,
      'autoGainControl': false,
      'googAutoGainControl': false,
      'googHighpassFilter': true,
      'googTypingNoiseDetection': false,
    },
  };

  final DatabaseReference _database;

  RTCPeerConnection? _pc;
  MediaStream? _localStream;

  /// Local mic mute state, toggled from the UI's dock. Purely a local
  /// `track.enabled` flip — never touches signaling, ICE, or the remote
  /// peer; the remote side simply receives silence while muted.
  bool _isMicMuted = false;
  bool get isMicMuted => _isMicMuted;

  /// Toggles the local microphone. Safe to call anytime, including before
  /// a local stream exists (no-op on the track loop, flag still flips so
  /// the UI stays consistent and `_ensureLocalAudioEnabled`/a later capture
  /// won't accidentally un-mute a user's deliberate mute).
  void toggleMic() {
    _isMicMuted = !_isMicMuted;
    final stream = _localStream;
    if (stream != null) {
      for (final track in stream.getAudioTracks()) {
        track.enabled = !_isMicMuted;
      }
    }
    debugPrint('[MeshTalk] mic ${_isMicMuted ? "muted" : "unmuted"}');
  }

  final List<RTCIceCandidate> _remoteCandidates = [];
  bool _isCaller = false;
  bool _remoteDescriptionSet = false;
  bool _handled = false;

  /// ICE diagnostic counters (reset per session; never affect behavior).
  int _localCandidateCount = 0;
  int _remoteReceivedCount = 0;
  int _remoteBufferedCount = 0;
  int _remoteAddedCount = 0;

  /// Last observed lifecycle states, purely for diagnostic snapshots; never
  /// read for control flow.
  RTCPeerConnectionState? _lastConnectionState;
  RTCIceConnectionState? _lastIceConnectionState;
  RTCIceGatheringState? _lastIceGatheringState;

  /// Diagnostic-only ICE candidate-pair stats polling (getStats). Never
  /// influences call state, ICE behavior, or lifecycle — purely
  /// observational, to determine which candidate pair(s) are actually being
  /// checked and whether any succeeds.
  Timer? _statsPollTimer;
  final Map<String, String> _lastPairSignatures = {};

  /// Call-duration timer. Started ONLY from the onIceConnectionState handler
  /// when ICE actually reaches RTCIceConnectionStateConnected — never from a
  /// UI event, never while merely "connecting". Auto-hangs-up at
  /// [_maxCallDurationSeconds] as a data/quota guard.
  Timer? _callTimer;
  int _elapsedSeconds = 0;
  static const int _maxCallDurationSeconds = 180;

  /// Notifies the UI once per second while the call timer is running, so it
  /// can re-read [formattedCallDuration]. Mirrors the existing
  /// [onStateChanged] callback pattern already used for signaling-state
  /// exposure — no new state-management primitive is introduced.
  void Function()? onCallDurationTick;

  /// Prevents the connection notice tone from replaying on transient ICE
  /// reconnects within the same session.
  bool _noticeTonePlayed = false;

  final NoticeTonePlayer _noticeTonePlayer = NoticeTonePlayer();

  /// Prevents the hangup tone from replaying more than once per session,
  /// since multiple call-ending signals (ICE Failed, then the resulting
  /// hangup()/_onCallEndedByRemote() cascade) can fire for the same event.
  bool _hangupTonePlayed = false;

  final HangupTonePlayer _hangupTonePlayer = HangupTonePlayer();

  /// Screen-off-near-ear during an active call. Started only once the call
  /// is truly connected, stopped the moment it stops being connected.
  final ProximityScreenController _proximityScreenController =
      ProximityScreenController();

  /// Keeps the process alive (persistent notification) while the Callee is
  /// in Standby, so Android/OEM battery management can't silently freeze or
  /// kill the Firebase RTDB `offer` listener. Started when Standby begins,
  /// stopped from [cleanupRoom] regardless of role — a no-op stop when it
  /// was never running (e.g. on the Caller) is harmless.
  final ForegroundServiceController _foregroundServiceController =
      ForegroundServiceController();

  /// Forces the physical display panel awake the instant a valid incoming
  /// offer is accepted on the Callee (see the `_offerSub` listener in
  /// [startCallee]) — a deep-sleep screen needs more than the existing
  /// `setShowWhenLocked`/`setTurnScreenOn` window flags, which only take
  /// effect once the Activity is already resumed.
  final ScreenWakeController _screenWakeController = ScreenWakeController();

  /// Timestamp (ms) when the Callee entered standby mode. Offers created
  /// before this moment are considered stale and must be ignored.
  int? _calleeActiveSinceMillis;

  /// Incremented on every start/cleanup so async callbacks from a previous
  /// session can be invalidated.
  int _sessionId = 0;

  /// Guards against re-entrant auto-reset (prevents infinite loops when both
  /// the Firebase null-offer and the WebRTC ICE disconnection fire together).
  bool _autoResetting = false;

  /// Re-entrancy lock for [cleanupRoom]. Owned and mutated only by
  /// [cleanupRoom] itself (set true at entry, reset false in `finally`);
  /// [hangup] only ever reads it to bail out early, never writes it —
  /// otherwise `hangup() -> cleanupRoom()` would deadlock itself, since
  /// cleanupRoom()'s own guard would see the flag already true and no-op.
  /// This is what prevents a mashed/duplicate Hangup button (or a UI hangup
  /// racing an auto-hangup) from running the full teardown sequence
  /// concurrently, over and over.
  bool _isCleaningUp = false;

  StreamSubscription<DatabaseEvent>? _offerSub;
  StreamSubscription<DatabaseEvent>? _answerSub;
  StreamSubscription<DatabaseEvent>? _callerCandidatesSub;
  StreamSubscription<DatabaseEvent>? _calleeCandidatesSub;

  /// Proactive network-transition detection (Wi-Fi <-> Cellular <-> none).
  /// On every real change, forces the Firebase RTDB socket reconnect cycle
  /// immediately — instead of waiting to discover a zombie socket reactively
  /// via a publish-offer/answer timeout.
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  List<ConnectivityResult>? _lastConnectivity;

  /// Real-time visibility into the RTDB SDK's own view of its connection
  /// health, via Firebase's special `.info/connected` path. Diagnostic-only
  /// logging — never read for control flow.
  StreamSubscription<DatabaseEvent>? _connectionInfoSub;

  SignalingState _state = SignalingState.idle;
  SignalingState get state => _state;

  void Function(SignalingState state)? onStateChanged;
  void Function(MediaStream stream)? onRemoteStream;

  /// Reacts to the app returning to the foreground by immediately forcing a
  /// fresh RTDB socket (see [_forceSocketReconnect]), rather than waiting to
  /// discover a possibly OS-frozen connection reactively via the next
  /// publish/candidate-push timeout. Never awaited by the framework, so this
  /// is necessarily fire-and-forget.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    debugPrint('[MeshTalk] app lifecycle state changed -> $state');
    if (state == AppLifecycleState.resumed) {
      unawaited(_forceSocketReconnect());
    }
  }

  void _setState(SignalingState state) {
    _state = state;
    debugPrint('[ICE][$_roleLabel][session=$_sessionId] signaling=$state');
    onStateChanged?.call(state);
  }

  String get _roleLabel => _isCaller ? 'CALLER' : 'CALLEE';

  /// Parses the candidate type (`host` / `srflx` / `relay`) from a raw ICE
  /// candidate string. Never logs credentials — only the type token.
  String _iceCandidateType(String? candidate) {
    if (candidate == null || candidate.isEmpty) return 'none';
    final parts = candidate.split(' ');
    for (var i = 0; i < parts.length - 1; i++) {
      if (parts[i] == 'typ') return parts[i + 1];
    }
    return 'unknown';
  }

  /// Non-sensitive address:port of a raw ICE candidate for diagnostics.
  String _iceCandidateEndpoint(String? candidate) {
    if (candidate == null || candidate.isEmpty) return '';
    final parts = candidate.split(' ');
    if (parts.length >= 6) return '${parts[4]}:${parts[5]}';
    return '';
  }

  /// One-line ICE counter summary, printed when the connection fails.
  void _logIceSummary(String label) {
    debugPrint(
      '[ICE][$_roleLabel][session=$_sessionId] $label '
      'localCandidates=$_localCandidateCount '
      'remoteReceived=$_remoteReceivedCount '
      'remoteBuffered=$_remoteBufferedCount '
      'remoteAdded=$_remoteAddedCount',
    );
  }

  /// One-line snapshot of every lifecycle flag relevant to diagnosing a
  /// stuck call: session id is already in the caller's log prefix, so this
  /// only carries the fields that aren't.
  String _lifecycleSnapshot() {
    return '(isCaller=$_isCaller signalingState=$_state '
        'connectionState=$_lastConnectionState '
        'iceConnectionState=$_lastIceConnectionState '
        'iceGatheringState=$_lastIceGatheringState)';
  }

  /// Wraps a single async boundary with before/after/error logging so a
  /// stuck startCaller/startCallee can be pinpointed to the exact operation
  /// that never completed. Never swallows: errors are logged, then rethrown
  /// unchanged so existing catch/recovery logic upstream is unaffected.
  Future<T> _traced<T>(
    String role,
    int session,
    String label,
    Future<T> Function() action,
  ) async {
    debugPrint('[$role][session=$session] before $label');
    try {
      final result = await action();
      debugPrint('[$role][session=$session] after $label');
      return result;
    } catch (error, stackTrace) {
      debugPrint('[$role][session=$session][ERROR] $label -> $error\n$stackTrace');
      rethrow;
    }
  }

  /// Diagnostic-only: starts a fixed-interval (2s) candidate-pair stats
  /// poll. No retry/backoff semantics — this is observation, not a control
  /// mechanism, and has zero effect on ICE/signaling behavior.
  void _startStatsPolling(String role, int session) {
    _stopStatsPolling();
    _lastPairSignatures.clear();
    _statsPollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_pollIceStats(role, session));
    });
  }

  void _stopStatsPolling() {
    _statsPollTimer?.cancel();
    _statsPollTimer = null;
  }

  /// Elapsed call duration formatted as `MM:SS`. Only meaningful once the
  /// timer has actually started (ICE reached Connected); "00:00" otherwise.
  String get formattedCallDuration {
    final minutes = (_elapsedSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (_elapsedSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  /// Starts the 1s call-duration ticker. Idempotent: a second call while
  /// already running is a no-op, so a repeated ICE "Connected" event (e.g.
  /// after a brief reconnect within the same session) never spawns a second
  /// ticking timer.
  void _startCallTimer() {
    if (_callTimer != null) return;
    _elapsedSeconds = 0;
    onCallDurationTick?.call();
    _callTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _elapsedSeconds++;
      onCallDurationTick?.call();
      if (_elapsedSeconds >= _maxCallDurationSeconds) {
        debugPrint(
          '[MeshTalk] call duration reached ${_maxCallDurationSeconds}s cap -> auto hangup',
        );
        // Stop the ticker synchronously first so a slow hangup() cannot let
        // a second tick fire and trigger a duplicate auto-hangup.
        _callTimer?.cancel();
        _callTimer = null;
        unawaited(hangup());
      }
    });
  }

  /// Cancels the call-duration ticker and resets the elapsed count. Safe to
  /// call anytime, including when no timer is running.
  void _stopCallTimer() {
    _callTimer?.cancel();
    _callTimer = null;
    _elapsedSeconds = 0;
  }

  /// Diagnostic-only: polls RTCPeerConnection.getStats(), resolves each
  /// candidate-pair report against its local/remote candidate reports, and
  /// logs a pair only when its observed state actually changed since the
  /// last poll (always, when [isFinalSnapshot] is true).
  Future<void> _pollIceStats(
    String role,
    int session, {
    bool isFinalSnapshot = false,
  }) async {
    if (session != _sessionId) return;
    final pc = _pc;
    if (pc == null) return;
    try {
      final reports = await pc.getStats();
      final localCandidates = <String, StatsReport>{};
      final remoteCandidates = <String, StatsReport>{};
      for (final report in reports) {
        if (report.type == 'local-candidate') {
          localCandidates[report.id] = report;
        } else if (report.type == 'remote-candidate') {
          remoteCandidates[report.id] = report;
        }
      }

      for (final report in reports) {
        if (report.type != 'candidate-pair') continue;
        final values = report.values;
        final localId = values['localCandidateId']?.toString();
        final remoteId = values['remoteCandidateId']?.toString();
        final local = localId != null ? localCandidates[localId] : null;
        final remote = remoteId != null ? remoteCandidates[remoteId] : null;

        final summary = '[STATS][$role][session=$session] pair=${report.id} '
            'state=${values['state']} nominated=${values['nominated']} '
            'bytesSent=${values['bytesSent']} bytesReceived=${values['bytesReceived']} '
            'requestsSent=${values['requestsSent']} responsesReceived=${values['responsesReceived']} '
            'requestsReceived=${values['requestsReceived']} responsesSent=${values['responsesSent']} '
            'local=(${_candidateStatsSummary(local)}) remote=(${_candidateStatsSummary(remote)})';

        if (isFinalSnapshot || _lastPairSignatures[report.id] != summary) {
          _lastPairSignatures[report.id] = summary;
          debugPrint(isFinalSnapshot ? '[STATS][FINAL] $summary' : summary);
        }
      }
    } catch (error) {
      debugPrint('[STATS][$role][session=$session] getStats ERROR: $error');
    }
  }

  /// Diagnostic-only: readable candidateType/address/port/protocol summary
  /// for a resolved local-candidate or remote-candidate stats report.
  String _candidateStatsSummary(StatsReport? report) {
    if (report == null) return 'unresolved';
    final values = report.values;
    final type = values['candidateType'];
    final address = values['address'] ?? values['ip'];
    final port = values['port'];
    final protocol = values['protocol'];
    return 'type=$type address=$address port=$port protocol=$protocol';
  }

  DatabaseReference get _roomRef => _database.child(roomPath);

  /// Forces the native Firebase RTDB SDK to tear down and re-establish its
  /// persistent socket, since that socket has been observed to go "zombie"
  /// (silently stop acking writes) after a Wi-Fi <-> cellular transition.
  ///
  /// `goOnline()` ALONE is not a reconnect: it only undoes a prior
  /// `goOffline()` call and is a no-op if the SDK still believes it's
  /// online — which is exactly the zombie-socket case, where the OS-level
  /// TCP connection is dead but the SDK's internal state hasn't noticed
  /// yet. The full `goOffline()` -> delay -> `goOnline()` cycle is what
  /// actually forces a fresh connection; this mirrors the cycle already
  /// proven to work in `cleanupRoom()`'s own timeout recovery, now shared
  /// via this single helper.
  Future<void> _forceSocketReconnect() async {
    try {
      await FirebaseDatabase.instance.goOffline();
      await Future.delayed(const Duration(milliseconds: 300));
      await FirebaseDatabase.instance.goOnline();
    } catch (error) {
      debugPrint('[MeshTalk] forced RTDB reconnect cycle failed (continuing anyway): $error');
    }
  }

  /// Hints the SDK to keep this room's data actively synced (rather than
  /// only while a listener is attached), so the connection has a persistent
  /// reason to stay warm. Fire-and-forget: this is an optimization, never a
  /// precondition for the call to proceed.
  void _keepRoomSynced() {
    unawaited(
      _roomRef.keepSynced(true).catchError((Object error) {
        debugPrint('[MeshTalk] keepSynced(true) failed (non-fatal): $error');
      }),
    );
  }

  /// Starts proactive network-transition detection. Every REAL change in
  /// connectivity type (the first event after subscribing is just the
  /// current baseline, not a transition) immediately triggers a forced RTDB
  /// reconnect cycle — catching a zombie socket at the moment it's created,
  /// instead of only discovering it reactively via a publish timeout later.
  void _startConnectivityMonitoring() {
    _stopConnectivityMonitoring();
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final previous = _lastConnectivity;
      _lastConnectivity = results;
      if (previous == null) {
        debugPrint('[MeshTalk] connectivity baseline: $results');
        return;
      }
      debugPrint(
        '[MeshTalk] connectivity changed: $previous -> $results -> forcing RTDB reconnect',
      );
      unawaited(_forceSocketReconnect());
    });
  }

  void _stopConnectivityMonitoring() {
    _connectivitySub?.cancel();
    _connectivitySub = null;
    _lastConnectivity = null;
  }

  /// Diagnostic-only: logs Firebase's own real-time view of whether the
  /// RTDB SDK currently has a live connection to the backend, via the
  /// special `.info/connected` path. Never read for control flow.
  void _startConnectionInfoLogging() {
    _stopConnectionInfoLogging();
    _connectionInfoSub =
        FirebaseDatabase.instance.ref('.info/connected').onValue.listen((event) {
      debugPrint('[MeshTalk] Firebase RTDB .info/connected = ${event.snapshot.value}');
    });
  }

  void _stopConnectionInfoLogging() {
    _connectionInfoSub?.cancel();
    _connectionInfoSub = null;
  }

  /// Starts screen-off-near-ear. Fire-and-forget: the native side is
  /// entirely responsible for the actual screen behavior, and a failure
  /// here (e.g. no proximity sensor on this device) must never affect the
  /// call itself.
  void _startProximityMonitoring() {
    unawaited(_proximityScreenController.start());
  }

  void _stopProximityMonitoring() {
    unawaited(_proximityScreenController.stop());
  }

  Future<RTCPeerConnection> _createPeerConnection() async {
    debugPrint('[MeshTalk] Creating PeerConnection (session=$_sessionId)');
    final pc = await createPeerConnection(_iceConfiguration);
    final session = _sessionId;
    _pc = pc;
    debugPrint('[MeshTalk] PeerConnection created (session=$session)');

    pc.onIceCandidate = (candidate) {
      if (session != _sessionId) return;
      if (candidate.candidate == null) return;
      _localCandidateCount++;
      final type = _iceCandidateType(candidate.candidate);
      final endpoint = _iceCandidateEndpoint(candidate.candidate);
      debugPrint(
        '[ICE][$_roleLabel][session=$session] LOCAL candidate type=$type endpoint=$endpoint (total=$_localCandidateCount)',
      );
      final node = _isCaller ? 'caller_candidates' : 'callee_candidates';
      _pushCandidate(node, candidate.toMap());
    };

    pc.onTrack = (event) async {
      if (session != _sessionId) return;

      debugPrint(
        '[MeshTalk][TRACK] onTrack event received. Streams length: ${event.streams.length}, '
        'track kind: ${event.track.kind}, track enabled: ${event.track.enabled}',
      );

      MediaStream targetStream;
      if (event.streams.isNotEmpty) {
        targetStream = event.streams.first;
      } else {
        // FIX: the old fallback assigned event.receiver?.track (a
        // MediaStreamTrack) to a MediaStream? slot, which could never pass
        // an `is MediaStream` check — onRemoteStream was silently never
        // called whenever a track arrived with no associated stream. Build
        // a real MediaStream around the bare track instead of losing it.
        debugPrint(
          '[MeshTalk][TRACK] event.streams is empty! Creating fallback MediaStream from event.track.',
        );
        final newStream = await createLocalMediaStream('remote_stream_${event.track.id}');
        await newStream.addTrack(event.track);
        targetStream = newStream;
      }

      debugPrint(
        '[MeshTalk][TRACK] Delivering remoteStream to listener. Audio tracks count: '
        '${targetStream.getAudioTracks().length}',
      );
      onRemoteStream?.call(targetStream);
    };

    pc.onConnectionState = (state) {
      if (session != _sessionId) return;
      _lastConnectionState = state;
      debugPrint('[ICE][$_roleLabel][session=$session] connection=$state');
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _setState(SignalingState.connected);
          // Screen-off-near-ear is tied to the same event that's the sole
          // authority for SignalingState.connected — never to ICE state or
          // any earlier signaling-complete point.
          _startProximityMonitoring();
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          _setState(SignalingState.failed);
          _logIceSummary('FAILED');
          _stopProximityMonitoring();
          _handlePeerDisconnected();
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          _setState(SignalingState.disconnected);
          _stopProximityMonitoring();
          _handlePeerDisconnected();
        default:
          break;
      }
    };

    pc.onIceConnectionState = (state) {
      if (session != _sessionId) return;
      _lastIceConnectionState = state;
      debugPrint('[ICE][$_roleLabel][session=$session] ice=$state');
      if (state == RTCIceConnectionState.RTCIceConnectionStateChecking) {
        // Diagnostic-only: ICE is now actively probing candidate pairs.
        _startStatsPolling(_roleLabel, session);
      }
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected) {
        _onPeerConnected();
        _stopStatsPolling();
        _startCallTimer();
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateClosed ||
          state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
          _logIceSummary('FAILED');
          // Diagnostic-only: one final unconditional stats snapshot at the
          // exact moment ICE fails.
          unawaited(_pollIceStats(_roleLabel, session, isFinalSnapshot: true));
        }
        _stopStatsPolling();
        _stopCallTimer();
        _playHangupToneOnce();
        _handlePeerDisconnected();
      }
    };

    pc.onIceGatheringState = (state) {
      if (session != _sessionId) return;
      _lastIceGatheringState = state;
      debugPrint('[ICE][$_roleLabel][session=$session] gathering=$state');
    };

    return pc;
  }

  Future<MediaStream> _getLocalStream() async {
    debugPrint('[MeshTalk] getUserMedia: requesting local audio...');
    final stream = await navigator.mediaDevices.getUserMedia({
      'audio': _audioConstraints,
      'video': false,
    });
    _localStream = stream;
    debugPrint(
      '[MeshTalk] getUserMedia: obtained ${stream.getAudioTracks().length} audio track(s)',
    );
    for (final track in stream.getAudioTracks()) {
      // Explicit, not just relying on getUserMedia's default: a track
      // created while `_isMicMuted` is stale (e.g. leaked across sessions)
      // must never come up silently muted, and a track created while the
      // user has genuinely muted must not come up accidentally live.
      track.enabled = !_isMicMuted;
      debugPrint(
        '[MeshTalk][MIC] ${_roleLabel[0]}${_roleLabel.substring(1).toLowerCase()} '
        'Local Track -> id: ${track.id}, enabled: ${track.enabled}, muted: ${track.muted}',
      );
      await _pc?.addTrack(track, stream);
    }
    return stream;
  }

  /// Defensive fix for devices whose audio policy may suspend or mute the
  /// microphone when the audio session is configured before the track is
  /// attached (e.g. Realme C12 / MediaTek). Re-asserts that every local audio
  /// track is explicitly enabled so the OS re-opens the capture path. Called
  /// exactly once, right after capture starts; never at connection time.
  void _ensureLocalAudioEnabled() {
    final stream = _localStream;
    if (stream == null) return;
    for (final track in stream.getAudioTracks()) {
      track.enabled = true;
    }
  }

  /// Routes the audio session as VoIP/voice-communication so Android uses
  /// `MODE_IN_COMMUNICATION` (activating the hardware secondary noise-cancelling
  /// microphone) with a `voiceCall` stream type. No-op on non-Android.
  Future<void> _configureVoipAudio() async {
    debugPrint('[MeshTalk] configuring VoIP audio (MODE_IN_COMMUNICATION)');
    await AndroidNativeAudioManagement.setAndroidAudioConfiguration(
      AndroidAudioConfiguration.communication,
    );
  }

  Future<void> _cancelSubscriptions() async {
    await _offerSub?.cancel();
    await _answerSub?.cancel();
    await _callerCandidatesSub?.cancel();
    await _calleeCandidatesSub?.cancel();
    _offerSub = null;
    _answerSub = null;
    _callerCandidatesSub = null;
    _calleeCandidatesSub = null;
  }

  Future<void> _closePeerConnection() async {
    _stopStatsPolling(); // diagnostic-only cleanup, no effect on ICE/signaling
    _stopCallTimer();
    _stopProximityMonitoring();
    debugPrint('[ICE][session=$_sessionId] closing peer connection');
    await _pc?.close();
    _pc = null;
    debugPrint('[ICE][session=$_sessionId] disposing local stream');
    final stream = _localStream;
    if (stream != null) {
      // Explicit per-track stop() BEFORE the stream itself is disposed: the
      // native Android plugin's `MediaStream.dispose()` only detaches tracks
      // from the stream container — it never calls the per-track
      // `trackDispose()` that actually releases the underlying AudioSource/
      // mic hardware. Without this loop, every call leaks one more native
      // audio track for the life of the process, which is why the mic
      // previously failed on the 2nd/3rd call until the app was killed.
      for (final track in stream.getTracks()) {
        try {
          await track.stop();
        } catch (error) {
          debugPrint('[MeshTalk] track.stop() failed (continuing anyway): $error');
        }
      }
    }
    await _localStream?.dispose();
    _localStream = null;
  }

  /// Reverts the native audio session to its pre-call default: mode back to
  /// `MODE_NORMAL` (via the package's own `.media` preset, the direct
  /// counterpart to the `.communication` preset `_configureVoipAudio`
  /// applies) and speakerphone forced off. `AudioSwitchManager` on the
  /// native side is a singleton that outlives any single call — it stays
  /// wherever the last call left it until explicitly told otherwise, which
  /// is why some OEM builds (HyperOS/MIUI, ColorOS) got stuck in in-call
  /// volume/routing after Hangup. Safe to call on every teardown path,
  /// including ones where no call was actually active yet — errors are
  /// caught and logged, never rethrown, since a failed reset must never
  /// block cleanup itself.
  Future<void> _resetAudioSession() async {
    try {
      debugPrint('[MeshTalk] resetting audio session -> MODE_NORMAL');
      await AndroidNativeAudioManagement.setAndroidAudioConfiguration(
        AndroidAudioConfiguration.media,
      );
      await Helper.setSpeakerphoneOn(false);
    } catch (error) {
      debugPrint('[MeshTalk] audio session reset failed (continuing anyway): $error');
    }
  }

  void _resetInternalState() {
    _remoteCandidates.clear();
    _isCaller = false;
    _remoteDescriptionSet = false;
    _handled = false;
    _calleeActiveSinceMillis = null;
    _noticeTonePlayed = false;
    _hangupTonePlayed = false;
    _isMicMuted = false;
    _localCandidateCount = 0;
    _remoteReceivedCount = 0;
    _remoteBufferedCount = 0;
    _remoteAddedCount = 0;
    _lastConnectionState = null;
    _lastIceConnectionState = null;
    _lastIceGatheringState = null;
    _lastPairSignatures.clear();
    _stopCallTimer();
    _stopConnectivityMonitoring();
    _stopConnectionInfoLogging();
    _stopProximityMonitoring();
  }

  /// Cleans the whole room (Firebase node + local WebRTC state) before
  /// starting a fresh handshake so no stale offer/answer/candidate is reused.
  Future<void> cleanupRoom() async {
    if (_isCleaningUp) {
      debugPrint('[ICE][session=$_sessionId] cleanupRoom SKIPPED (already in progress)');
      return;
    }
    _isCleaningUp = true;
    final cleanupSession = _sessionId;
    debugPrint('[ICE][session=$cleanupSession] cleanupRoom START ${_lifecycleSnapshot()}');
    _sessionId++;
    try {
      debugPrint('[ICE][session=$cleanupSession] cleanupRoom: cancelling listeners');
      await _cancelSubscriptions();

      // Logs "closing peer connection" / "disposing local stream" internally.
      await _closePeerConnection();

      debugPrint('[ICE][session=$cleanupSession] cleanupRoom: removing Firebase room');
      try {
        await _roomRef.remove().timeout(const Duration(seconds: 3));
      } on TimeoutException catch (_) {
        debugPrint(
          '[MeshTalk] Firebase remove timed out (Zombie Connection). Forcing RTDB reconnect...',
        );
        await _forceSocketReconnect();
      } catch (e) {
        debugPrint('[MeshTalk] Error removing room node: $e');
      }

      await _noticeTonePlayer.dispose();
      // Stopped unconditionally regardless of role — a no-op when it was
      // never running (e.g. cleanupRoom() called from the Caller side).
      await _foregroundServiceController.stop();
      // Single shared choke-point for hangup, remote disconnect, failed
      // handshake, and cancel — cleanupRoom() is called from all of them,
      // so resetting the audio session here covers every one of those
      // scenarios without needing a separate call at each site.
      await _resetAudioSession();
      _resetInternalState();
      debugPrint('[ICE][session=$cleanupSession] cleanupRoom COMPLETE');
    } catch (error, stackTrace) {
      debugPrint('[ICE][session=$cleanupSession][ERROR] cleanupRoom -> $error\n$stackTrace');
      rethrow;
    } finally {
      _isCleaningUp = false;
    }
  }

  Future<void> startCaller({
    required void Function(MediaStream stream) onRemoteStream,
    required void Function(SignalingState state) onStateChanged,
  }) async {
    this.onRemoteStream = onRemoteStream;
    this.onStateChanged = onStateChanged;

    debugPrint('[CALLER][session=$_sessionId] START ${_lifecycleSnapshot()}');

    debugPrint('[CALLER][session=$_sessionId] before cleanupRoom');
    try {
      await cleanupRoom();
      debugPrint('[CALLER][session=$_sessionId] after cleanupRoom');
    } catch (error, stackTrace) {
      debugPrint('[CALLER][session=$_sessionId][ERROR] cleanupRoom -> $error\n$stackTrace');
      rethrow;
    }

    _isCaller = true;
    _setState(SignalingState.connecting);
    debugPrint('[MeshTalk] startCaller: entered caller mode');
    _keepRoomSynced();
    _startConnectivityMonitoring();
    _startConnectionInfoLogging();

    await _traced('CALLER', _sessionId, 'configureVoipAudio', _configureVoipAudio);
    final session = ++_sessionId;
    debugPrint('[MeshTalk] startCaller: session=$session');

    // The whole handshake (PC creation, media capture, SDP, offer publish) is
    // guarded so a failure at any stage — most notably a slow cellular
    // socket blowing the publish-offer timeout — is logged, cleanly resets
    // the session (failed state + timer stop + full cleanupRoom), and never
    // leaves the UI stuck on "Menghubungi..." with a leaked PeerConnection.
    try {
      await _traced('CALLER', session, 'createPeerConnection', _createPeerConnection);
      await _traced('CALLER', session, 'getLocalStream', _getLocalStream);

      final offer = await _traced(
        'CALLER',
        session,
        'createOffer',
        () => _pc!.createOffer(),
      );
      await _traced(
        'CALLER',
        session,
        'setLocalDescription',
        () => _pc!.setLocalDescription(offer),
      );
      // Force the native socket awake before the write it's actually needed
      // for — this is the step observed to be asleep after a cellular
      // network transition.
      await _traced('CALLER', session, 'forceSocketReconnect', _forceSocketReconnect);
      await _traced(
        'CALLER',
        session,
        'publish offer',
        () => _roomRef.child('offer').set({
          ...offer.toMap(),
          'createdAt': DateTime.now().millisecondsSinceEpoch,
        }).timeout(const Duration(seconds: 10)),
      );

      // Register the callee candidate listener early so candidates arriving
      // before the answer is processed are buffered, not lost.
      _listenCandidates(
        node: 'callee_candidates',
        subscription: (sub) => _calleeCandidatesSub = sub,
      );
      debugPrint('[CALLER][session=$session] listener callee_candidates installed');

      _answerSub = _roomRef.child('answer').onValue.listen((event) async {
        if (session != _sessionId) return;
        if (_remoteDescriptionSet || _pc == null) return;

        final value = event.snapshot.value;
        if (value == null) return;
        debugPrint('[MeshTalk] startCaller: answer received (session=$session)');
        final data = Map<String, dynamic>.from(value as Map);
        if (data.isEmpty) return;

        final description = RTCSessionDescription(
          data['sdp'] as String,
          data['type'] as String,
        );
        try {
          await _pc!.setRemoteDescription(description);
        } catch (error, stackTrace) {
          debugPrint(
            '[CALLER][session=$session][ERROR] setRemoteDescription(answer) -> $error\n$stackTrace',
          );
          rethrow;
        }
        _remoteDescriptionSet = true;
        debugPrint(
          '[MeshTalk] startCaller: remoteDescriptionSet, flushing ${_remoteCandidates.length} buffered candidate(s)',
        );
        await _flushRemoteCandidates();
        // Signaling is complete here, but this is NOT a connectivity guarantee.
        // The only path to SignalingState.connected is pc.onConnectionState
        // reaching RTCPeerConnectionStateConnected (see _createPeerConnection).
      });
      debugPrint('[CALLER][session=$session] listener answer installed');

      debugPrint('[CALLER][session=$session] START COMPLETE ${_lifecycleSnapshot()}');
    } catch (error, stackTrace) {
      debugPrint(
        '[CALLER][session=$session][ERROR] startCaller handshake failed: $error\n$stackTrace',
      );
      _setState(SignalingState.failed);
      _stopCallTimer();
      await cleanupRoom();
    }
  }

  Future<void> startCallee({
    required void Function(MediaStream stream) onRemoteStream,
    required void Function(SignalingState state) onStateChanged,
  }) async {
    this.onRemoteStream = onRemoteStream;
    this.onStateChanged = onStateChanged;

    debugPrint('[CALLEE][session=$_sessionId] START ${_lifecycleSnapshot()}');

    debugPrint('[CALLEE][session=$_sessionId] before cleanupRoom');
    try {
      await cleanupRoom();
      debugPrint('[CALLEE][session=$_sessionId] after cleanupRoom');
    } catch (error, stackTrace) {
      debugPrint('[CALLEE][session=$_sessionId][ERROR] cleanupRoom -> $error\n$stackTrace');
      rethrow;
    }

    _isCaller = false;
    // Explicit on top of _resetInternalState()'s own reset (already run by
    // the cleanupRoom() call above): a fresh standby session must never
    // inherit a mute flag from whatever state the previous call ended in.
    _isMicMuted = false;
    _calleeActiveSinceMillis = DateTime.now().millisecondsSinceEpoch;
    debugPrint('[MeshTalk] startCallee: standby active (activeSince=$_calleeActiveSinceMillis)');
    _keepRoomSynced();
    _startConnectivityMonitoring();
    _startConnectionInfoLogging();
    // Fire-and-forget: a foreground-service failure (e.g. denied
    // notification permission) must never block entering Standby itself.
    unawaited(_foregroundServiceController.start());

    // Note: `setSpeakerphoneOn(true)` is intentionally NOT called here. Doing
    // so at standby pre-activates the AudioSwitch / routes to the speaker
    // before any capture track exists, which can lock the hardware mic on
    // MediaTek budget devices (e.g. Realme C12). It is applied later, after
    // the offer is processed and the audio track is attached.
    await _traced('CALLEE', _sessionId, 'configureVoipAudio', _configureVoipAudio);
    _setState(SignalingState.connecting);

    final session = ++_sessionId;
    debugPrint('[MeshTalk] startCallee: session=$session, waiting for offer');

    // Register the caller candidate listener early so no candidate is missed
    // while we wait for the offer. Candidates are buffered until the remote
    // description is set.
    _listenCandidates(
      node: 'caller_candidates',
      subscription: (sub) => _callerCandidatesSub = sub,
    );
    debugPrint('[CALLEE][session=$session] listener caller_candidates installed');

    _offerSub = _roomRef.child('offer').onValue.listen((event) async {
      if (session != _sessionId) return;

      final value = event.snapshot.value;
      if (value == null) {
        // The Caller removed the room (hangup / cleanup) while we were in an
        // active call: tear down and re-enter standby automatically.
        if (_handled && _pc != null) {
          debugPrint('[MeshTalk] callee: offer node cleared during active call -> remote ended call');
          await _onCallEndedByRemote();
        }
        return;
      }
      final data = Map<String, dynamic>.from(value as Map);
      if (data.isEmpty) return;

      // Reject offers created before this Callee entered standby mode.
      final createdAt = int.tryParse(data['createdAt']?.toString() ?? '');
      final activeSince = _calleeActiveSinceMillis;
      if (createdAt == null || activeSince == null || createdAt < activeSince) {
        debugPrint(
          '[MeshTalk] callee: offer REJECTED as stale (createdAt=$createdAt, activeSince=$activeSince)',
        );
        return;
      }

      debugPrint(
        '[MeshTalk] callee: offer accepted (session=$session, handled=$_handled, pc=${_pc != null}, sdpLen=${(data['sdp'] as String?)?.length ?? 0})',
      );
      if (_handled || _pc != null) return;
      _handled = true;
      debugPrint('[CALLEE][session=$session] offer received ${_lifecycleSnapshot()}');
      // Earliest confirmed-valid-offer point: fire the physical screen
      // wake-up here, before any WebRTC/SDP work, so the panel is already
      // lit by the time the call UI renders.
      unawaited(_screenWakeController.wake());

      final offer = RTCSessionDescription(
        data['sdp'] as String,
        data['type'] as String,
      );

      // The whole handshake (PC creation, media capture, SDP, answer publish)
      // is guarded so a failure at any stage is logged, resets the session
      // state, and surfaces as `failed` instead of silently deadlocking.
      try {
        // 1. Create the PeerConnection (MANDATORY) before touching local
        //    media so the ICE agent exists to receive/queue candidates.
        await _traced('CALLEE', session, 'createPeerConnection', _createPeerConnection);

        // 2. Local stream (fresh, guarded with a 10s hang-cap for slow
        //    MediaTek audio HALs) + defensive re-enable of capture track.
        _localStream ??= await _traced(
          'CALLEE',
          session,
          'getLocalStream',
          () => _getLocalStream().timeout(const Duration(seconds: 10)),
        );
        _ensureLocalAudioEnabled();

        // 3. Pure, sequential SDP transaction.
        await _traced(
          'CALLEE',
          session,
          'setRemoteDescription',
          () => _pc!.setRemoteDescription(offer),
        );
        _remoteDescriptionSet = true;

        final answer = await _traced(
          'CALLEE',
          session,
          'createAnswer',
          () => _pc!.createAnswer(),
        );
        await _traced(
          'CALLEE',
          session,
          'setLocalDescription',
          () => _pc!.setLocalDescription(answer),
        );

        // Force the native socket awake before the write it's actually
        // needed for — this is the step observed to be asleep after a
        // cellular network transition.
        await _traced('CALLEE', session, 'forceSocketReconnect', _forceSocketReconnect);

        // Publish the answer, then flush buffered ICE candidates.
        await _traced(
          'CALLEE',
          session,
          'publish answer',
          () => _roomRef.child('answer').set(answer.toMap()).timeout(const Duration(seconds: 10)),
        );
        await _traced('CALLEE', session, 'flush candidates', _flushRemoteCandidates);

        // Route to the speaker after the handshake is committed. This is the
        // single lifecycle point for speakerphone on the Callee; it is never
        // re-toggled from connection/ICE callbacks.
        debugPrint('[MeshTalk] callee: enabling speakerphone');
        await Helper.setSpeakerphoneOn(true);

        debugPrint('[CALLEE][session=$session] HANDSHAKE COMPLETE ${_lifecycleSnapshot()}');
        // Signaling is complete here, but this is NOT a connectivity guarantee.
        // The only path to SignalingState.connected is pc.onConnectionState
        // reaching RTCPeerConnectionStateConnected (see _createPeerConnection).
      } catch (error, stackTrace) {
        debugPrint('[MeshTalk] callee: handshake failed: $error\n$stackTrace');
        // Release the session state so a retry/next offer is not blocked.
        _handled = false;
        _remoteDescriptionSet = false;
        await _closePeerConnection();
        _stopCallTimer();
        _setState(SignalingState.failed);
      }
    });
    debugPrint('[CALLEE][session=$session] listener offer installed');

    debugPrint('[CALLEE][session=$session] START COMPLETE ${_lifecycleSnapshot()}');
  }

  void _listenCandidates({
    required String node,
    required void Function(StreamSubscription<DatabaseEvent>) subscription,
  }) {
    subscription(_roomRef.child(node).onChildAdded.listen((event) async {
      if (event.snapshot.value == null) return;
      _remoteReceivedCount++;

      final data = Map<String, dynamic>.from(event.snapshot.value as Map);
      final rawCandidate = data['candidate'] as String?;
      final candidate = RTCIceCandidate(
        rawCandidate,
        data['sdpMid'] as String?,
        int.tryParse(data['sdpMLineIndex']?.toString() ?? '') ?? 0,
      );
      final type = _iceCandidateType(rawCandidate);
      final endpoint = _iceCandidateEndpoint(rawCandidate);

      // A candidate arriving while the PeerConnection is still missing
      // (Callee in standby / mid-initialization) is buffered, never dropped,
      // so the ICE handshake cannot be starved of remote candidates. It is
      // flushed once the remote description is set.
      if (_pc == null) {
        _remoteBufferedCount++;
        _remoteCandidates.add(candidate);
        debugPrint(
          '[ICE][$_roleLabel][session=$_sessionId] REMOTE candidate type=$type endpoint=$endpoint action=buffered (pc==null, total=${_remoteCandidates.length})',
        );
        return;
      }

      if (_remoteDescriptionSet) {
        _remoteAddedCount++;
        try {
          debugPrint(
            '[ICE][$_roleLabel][session=$_sessionId] REMOTE candidate type=$type endpoint=$endpoint action=added',
          );
          await _pc!.addCandidate(candidate);
        } catch (error) {
          debugPrint('[ICE][$_roleLabel][session=$_sessionId] addCandidate ERROR: $error');
        }
      } else {
        _remoteBufferedCount++;
        _remoteCandidates.add(candidate);
        debugPrint(
          '[ICE][$_roleLabel][session=$_sessionId] REMOTE candidate type=$type endpoint=$endpoint action=buffered (total=${_remoteCandidates.length})',
        );
      }
    }));
  }

  Future<void> _flushRemoteCandidates() async {
    final pc = _pc;
    final flushCount = _remoteCandidates.length;
    debugPrint(
      '[ICE][$_roleLabel][session=$_sessionId] FLUSH START count=$flushCount',
    );
    if (pc == null) {
      _remoteCandidates.clear();
      debugPrint(
        '[ICE][$_roleLabel][session=$_sessionId] FLUSH DONE count=0 (pc==null)',
      );
      return;
    }
    for (final candidate in _remoteCandidates) {
      final type = _iceCandidateType(candidate.candidate);
      final endpoint = _iceCandidateEndpoint(candidate.candidate);
      try {
        debugPrint(
          '[ICE][$_roleLabel][session=$_sessionId] FLUSH remote candidate type=$type endpoint=$endpoint',
        );
        await pc.addCandidate(candidate);
        _remoteAddedCount++;
      } catch (error) {
        debugPrint('[ICE][$_roleLabel][session=$_sessionId] FLUSH addCandidate ERROR: $error');
      }
    }
    _remoteCandidates.clear();
    debugPrint(
      '[ICE][$_roleLabel][session=$_sessionId] FLUSH DONE count=$flushCount',
    );
  }

  Future<void> _pushCandidate(String node, Map<String, dynamic> candidate) async {
    final type = _iceCandidateType(candidate['candidate'] as String?);
    final endpoint = _iceCandidateEndpoint(candidate['candidate'] as String?);
    debugPrint(
      '[ICE][$_roleLabel][session=$_sessionId] PUSH candidate START type=$type endpoint=$endpoint node=$node',
    );
    // Called fire-and-forget from pc.onIceCandidate (never awaited). A
    // single missed candidate is not fatal to the call — ICE just checks
    // fewer pairs — so failures here are caught and silently ignored rather
    // than ever propagating into (and derailing) the main call flow.
    try {
      await _roomRef.child(node).push().set(candidate);
      debugPrint(
        '[ICE][$_roleLabel][session=$_sessionId] PUSH candidate DONE node=$node',
      );
    } catch (error) {
      debugPrint(
        '[ICE][$_roleLabel][session=$_sessionId] PUSH candidate ERROR node=$node (ignored): $error',
      );
    }
  }

  /// Network-level disconnection (ICE or RTCPeerConnection) detected on the
  /// Callee while a call is active.
  void _handlePeerDisconnected() {
    debugPrint('[MeshTalk] _handlePeerDisconnected (caller=$_isCaller, handled=$_handled, pc=${_pc != null})');
    if (_isCaller || !_handled || _pc == null) return;
    _onCallEndedByRemote();
  }

  /// WebRTC connection established on the Callee: plays the one-shot notice
  /// tone (non-blocking) only once per session to alert people at home that
  /// the intercom channel is open.
  void _onPeerConnected() {
    if (_isCaller) return;
    if (_noticeTonePlayed) return;
    _noticeTonePlayed = true;
    debugPrint('[MeshTalk] ICE connected on callee -> playing notice tone');
    // Fire-and-forget with error isolation: a native audio failure (e.g. on
    // Realme C12) must never interrupt, restart, or disconnect the WebRTC
    // call. The tone is purely cosmetic and never awaited by the call lifecycle.
    unawaited(
      _noticeTonePlayer.play().catchError((Object error) {
        debugPrint('[NOTICE_TONE] playback failed (call continues): $error');
      }),
    );
  }

  /// Plays the one-shot hangup/disconnect tone at most once per session
  /// (guarded by [_hangupTonePlayed], reset on the next [_resetInternalState]).
  /// Fire-and-forget with full error isolation, mirroring [_onPeerConnected]:
  /// a native audio failure must never block or delay cleanupRoom()/
  /// PeerConnection teardown, and is never awaited by any call-ending path.
  void _playHangupToneOnce() {
    if (_hangupTonePlayed) return;
    _hangupTonePlayed = true;
    debugPrint('[MeshTalk] call ending -> playing hangup tone');
    unawaited(
      _hangupTonePlayer.play().catchError((Object error) {
        debugPrint('[HANGUP_TONE] playback failed (cleanup continues): $error');
      }),
    );
  }

  /// The remote peer ended the call (caller hangup / network drop). Callee
  /// cleans up all resources and automatically re-enters standby mode.
  Future<void> _onCallEndedByRemote() async {
    if (_autoResetting) return;
    _autoResetting = true;
    _playHangupToneOnce();
    try {
      if (_isCaller) {
        debugPrint('[MeshTalk] remote ended call on caller -> hangup');
        await hangup();
        return;
      }
      debugPrint('[MeshTalk] remote ended call on callee -> re-enter standby');

      final onRemote = onRemoteStream;
      final onState = onStateChanged;
      if (onRemote == null || onState == null) return;

      await cleanupRoom();
      await startCallee(onRemoteStream: onRemote, onStateChanged: onState);
    } finally {
      _autoResetting = false;
    }
  }

  Future<void> hangup() async {
    if (_isCleaningUp) {
      debugPrint('[MeshTalk] hangup ignored: cleanup already in progress');
      return;
    }
    debugPrint('[MeshTalk] hangup requested');
    _playHangupToneOnce();
    await cleanupRoom();
    _setState(SignalingState.idle);
  }

  Future<void> dispose() async {
    WidgetsBinding.instance.removeObserver(this);
    await hangup();
  }
}