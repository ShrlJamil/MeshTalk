import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'notice_tone_player.dart';

enum SignalingState {
  idle,
  connecting,
  connected,
  disconnected,
  failed,
}

class SignalingService {
  SignalingService({DatabaseReference? database})
      : _database = database ?? FirebaseDatabase.instance.ref();

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

  /// Audio constraints enabling Google WebRTC voice processing (echo
  /// cancellation, noise suppression, auto gain control, high-pass filter).
  /// Both Android and native iOS parse the `mandatory`/`optional` structure
  /// and skip their defaults when a Map is provided, so every key is set
  /// explicitly here.
  static const Map<String, dynamic> _audioConstraints = {
    'mandatory': {
      'echoCancellation': true,
      'googEchoCancellation': true,
      'googEchoCancellation2': true,
      'googDAEchoCancellation': true,
      'noiseSuppression': true,
      'googNoiseSuppression': true,
      'autoGainControl': true,
      'googAutoGainControl': true,
      'googHighpassFilter': true,
      'googTypingNoiseDetection': false,
    },
    'optional': [
      {'googNoiseSuppression': true},
      {'googEchoCancellation': true},
      {'googAutoGainControl': true},
      {'googHighpassFilter': true},
    ],
  };

  final DatabaseReference _database;

  RTCPeerConnection? _pc;
  MediaStream? _localStream;

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

  /// Prevents the connection notice tone from replaying on transient ICE
  /// reconnects within the same session.
  bool _noticeTonePlayed = false;

  final NoticeTonePlayer _noticeTonePlayer = NoticeTonePlayer();

  /// Timestamp (ms) when the Callee entered standby mode. Offers created
  /// before this moment are considered stale and must be ignored.
  int? _calleeActiveSinceMillis;

  /// Incremented on every start/cleanup so async callbacks from a previous
  /// session can be invalidated.
  int _sessionId = 0;

  /// Guards against re-entrant auto-reset (prevents infinite loops when both
  /// the Firebase null-offer and the WebRTC ICE disconnection fire together).
  bool _autoResetting = false;

  StreamSubscription<DatabaseEvent>? _offerSub;
  StreamSubscription<DatabaseEvent>? _answerSub;
  StreamSubscription<DatabaseEvent>? _callerCandidatesSub;
  StreamSubscription<DatabaseEvent>? _calleeCandidatesSub;

  SignalingState _state = SignalingState.idle;
  SignalingState get state => _state;

  void Function(SignalingState state)? onStateChanged;
  void Function(MediaStream stream)? onRemoteStream;

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

    pc.onTrack = (event) {
      if (session != _sessionId) return;
      final stream = event.streams.isNotEmpty ? event.streams.first : event.receiver?.track;
      if (stream is MediaStream) {
        onRemoteStream?.call(stream);
      }
    };

    pc.onConnectionState = (state) {
      if (session != _sessionId) return;
      _lastConnectionState = state;
      debugPrint('[ICE][$_roleLabel][session=$session] connection=$state');
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _setState(SignalingState.connected);
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          _setState(SignalingState.failed);
          _logIceSummary('FAILED');
          _handlePeerDisconnected();
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          _setState(SignalingState.disconnected);
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
    debugPrint('[ICE][session=$_sessionId] closing peer connection');
    await _pc?.close();
    _pc = null;
    debugPrint('[ICE][session=$_sessionId] disposing local stream');
    await _localStream?.dispose();
    _localStream = null;
  }

  void _resetInternalState() {
    _remoteCandidates.clear();
    _isCaller = false;
    _remoteDescriptionSet = false;
    _handled = false;
    _calleeActiveSinceMillis = null;
    _noticeTonePlayed = false;
    _localCandidateCount = 0;
    _remoteReceivedCount = 0;
    _remoteBufferedCount = 0;
    _remoteAddedCount = 0;
    _lastConnectionState = null;
    _lastIceConnectionState = null;
    _lastIceGatheringState = null;
    _lastPairSignatures.clear();
  }

  /// Cleans the whole room (Firebase node + local WebRTC state) before
  /// starting a fresh handshake so no stale offer/answer/candidate is reused.
  Future<void> cleanupRoom() async {
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
        try {
          await FirebaseDatabase.instance.goOffline();
          await FirebaseDatabase.instance.goOnline();
        } catch (e) {
          debugPrint('[MeshTalk] Error resetting RTDB connection: $e');
        }
      } catch (e) {
        debugPrint('[MeshTalk] Error removing room node: $e');
      }

      await _noticeTonePlayer.dispose();
      _resetInternalState();
      debugPrint('[ICE][session=$cleanupSession] cleanupRoom COMPLETE');
    } catch (error, stackTrace) {
      debugPrint('[ICE][session=$cleanupSession][ERROR] cleanupRoom -> $error\n$stackTrace');
      rethrow;
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

    await _traced('CALLER', _sessionId, 'configureVoipAudio', _configureVoipAudio);
    final session = ++_sessionId;
    debugPrint('[MeshTalk] startCaller: session=$session');

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
    await _traced(
      'CALLER',
      session,
      'publish offer',
      () => _roomRef.child('offer').set({
        ...offer.toMap(),
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      }).timeout(const Duration(seconds: 4)),
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
    _calleeActiveSinceMillis = DateTime.now().millisecondsSinceEpoch;
    debugPrint('[MeshTalk] startCallee: standby active (activeSince=$_calleeActiveSinceMillis)');

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

        // Publish the answer, then flush buffered ICE candidates.
        await _traced(
          'CALLEE',
          session,
          'publish answer',
          () => _roomRef.child('answer').set(answer.toMap()).timeout(const Duration(seconds: 4)),
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
    await _roomRef.child(node).push().set(candidate);
    debugPrint(
      '[ICE][$_roleLabel][session=$_sessionId] PUSH candidate DONE node=$node',
    );
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

  /// The remote peer ended the call (caller hangup / network drop). Callee
  /// cleans up all resources and automatically re-enters standby mode.
  Future<void> _onCallEndedByRemote() async {
    if (_autoResetting) return;
    _autoResetting = true;
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
    debugPrint('[MeshTalk] hangup requested');
    await cleanupRoom();
    _setState(SignalingState.idle);
  }

  Future<void> dispose() => hangup();
}