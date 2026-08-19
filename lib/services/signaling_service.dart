import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
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

  static const Map<String, dynamic> _iceConfiguration = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
    ],
  };

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
    onStateChanged?.call(state);
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
      final node = _isCaller ? 'caller_candidates' : 'callee_candidates';
      debugPrint('[MeshTalk] Local ICE candidate -> $node');
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
      debugPrint('[MeshTalk] onConnectionState=$state (caller=$_isCaller, handled=$_handled)');
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _setState(SignalingState.connected);
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          _setState(SignalingState.failed);
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
      debugPrint('[MeshTalk] onIceConnectionState=$state (caller=$_isCaller, handled=$_handled)');
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected) {
        _onPeerConnected();
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateClosed ||
          state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        _handlePeerDisconnected();
      }
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
  /// track is explicitly enabled so the OS re-opens the capture path.
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
    await _pc?.close();
    _pc = null;
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
  }

  /// Cleans the whole room (Firebase node + local WebRTC state) before
  /// starting a fresh handshake so no stale offer/answer/candidate is reused.
  Future<void> cleanupRoom() async {
    debugPrint('[MeshTalk] cleanupRoom: session=$_sessionId, removing room node');
    _sessionId++;
    await _cancelSubscriptions();
    await _closePeerConnection();
    await _roomRef.remove();
    await _noticeTonePlayer.dispose();
    _resetInternalState();
  }

  Future<void> startCaller({
    required void Function(MediaStream stream) onRemoteStream,
    required void Function(SignalingState state) onStateChanged,
  }) async {
    this.onRemoteStream = onRemoteStream;
    this.onStateChanged = onStateChanged;

    await cleanupRoom();
    _isCaller = true;
    _setState(SignalingState.connecting);
    debugPrint('[MeshTalk] startCaller: entered caller mode');

    await _configureVoipAudio();
    final session = ++_sessionId;
    debugPrint('[MeshTalk] startCaller: session=$session');

    await _createPeerConnection();
    await _getLocalStream();

    final offer = await _pc!.createOffer();
    await _pc!.setLocalDescription(offer);
    await _roomRef.child('offer').set({
      ...offer.toMap(),
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    });
    debugPrint('[MeshTalk] startCaller: offer written to Firebase');

    // Register the callee candidate listener early so candidates arriving
    // before the answer is processed are buffered, not lost.
    _listenCandidates(
      node: 'callee_candidates',
      subscription: (sub) => _calleeCandidatesSub = sub,
    );
    debugPrint('[MeshTalk] startCaller: listening for callee_candidates');

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
      await _pc!.setRemoteDescription(description);
      _remoteDescriptionSet = true;
      debugPrint(
        '[MeshTalk] startCaller: remoteDescriptionSet, flushing ${_remoteCandidates.length} buffered candidate(s)',
      );
      await _flushRemoteCandidates();
      _setState(SignalingState.connected);
    });
  }

  Future<void> startCallee({
    required void Function(MediaStream stream) onRemoteStream,
    required void Function(SignalingState state) onStateChanged,
  }) async {
    this.onRemoteStream = onRemoteStream;
    this.onStateChanged = onStateChanged;

    await cleanupRoom();
    _isCaller = false;
    _calleeActiveSinceMillis = DateTime.now().millisecondsSinceEpoch;
    debugPrint('[MeshTalk] startCallee: standby active (activeSince=$_calleeActiveSinceMillis)');

    // Note: `setSpeakerphoneOn(true)` is intentionally NOT called here. Doing
    // so at standby pre-activates the AudioSwitch / routes to the speaker
    // before any capture track exists, which can lock the hardware mic on
    // MediaTek budget devices (e.g. Realme C12). It is applied later, after
    // the offer is processed and the audio track is attached.
    await _configureVoipAudio();
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
    debugPrint('[MeshTalk] startCallee: listening for caller_candidates');

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
        await _createPeerConnection();

        // 2. Local stream (fresh, guarded with a 10s hang-cap for slow
        //    MediaTek audio HALs) + defensive re-enable of capture track.
        _localStream ??= await _getLocalStream().timeout(
          const Duration(seconds: 10),
        );
        _ensureLocalAudioEnabled();

        // 3. Pure, sequential SDP transaction.
        debugPrint('[MeshTalk] callee: setRemoteDescription(offer)...');
        await _pc!.setRemoteDescription(offer);
        _remoteDescriptionSet = true;

        debugPrint('[MeshTalk] callee: createAnswer...');
        final answer = await _pc!.createAnswer();
        await _pc!.setLocalDescription(answer);

        // Publish the answer, then flush buffered ICE candidates.
        debugPrint(
          '[MeshTalk] callee: publishing answer + flushing ${_remoteCandidates.length} buffered candidate(s)',
        );
        await _roomRef.child('answer').set(answer.toMap());
        await _flushRemoteCandidates();

        // Route to the speaker after the handshake is committed.
        debugPrint('[MeshTalk] callee: enabling speakerphone');
        await Helper.setSpeakerphoneOn(true);

        _ensureLocalAudioEnabled();
        _setState(SignalingState.connected);
      } catch (error, stackTrace) {
        debugPrint('[MeshTalk] callee: handshake failed: $error\n$stackTrace');
        // Release the session state so a retry/next offer is not blocked.
        _handled = false;
        _remoteDescriptionSet = false;
        await _closePeerConnection();
        _setState(SignalingState.failed);
      }
    });
  }

  void _listenCandidates({
    required String node,
    required void Function(StreamSubscription<DatabaseEvent>) subscription,
  }) {
    subscription(_roomRef.child(node).onChildAdded.listen((event) async {
      if (event.snapshot.value == null) return;

      final data = Map<String, dynamic>.from(event.snapshot.value as Map);
      final candidate = RTCIceCandidate(
        data['candidate'] as String,
        data['sdpMid'] as String?,
        int.tryParse(data['sdpMLineIndex']?.toString() ?? '') ?? 0,
      );

      // A candidate arriving while the PeerConnection is still missing
      // (Callee in standby / mid-initialization) is buffered, never dropped,
      // so the ICE handshake cannot be starved of remote candidates. It is
      // flushed once the remote description is set.
      if (_pc == null) {
        _remoteCandidates.add(candidate);
        debugPrint(
          '[MeshTalk] candidate($node): buffered (pc==null, total=${_remoteCandidates.length})',
        );
        return;
      }

      if (_remoteDescriptionSet) {
        try {
          debugPrint('[MeshTalk] candidate($node): added to peer (remoteDescSet=true)');
          await _pc!.addCandidate(candidate);
        } catch (error) {
          debugPrint('[MeshTalk] Failed to add remote candidate: $error');
        }
      } else {
        _remoteCandidates.add(candidate);
        debugPrint(
          '[MeshTalk] candidate($node): buffered (total=${_remoteCandidates.length}, remoteDescSet=false)',
        );
      }
    }));
  }

  Future<void> _flushRemoteCandidates() async {
    final pc = _pc;
    debugPrint('[MeshTalk] flushing ${_remoteCandidates.length} buffered remote candidate(s)');
    if (pc == null) {
      _remoteCandidates.clear();
      return;
    }
    for (final candidate in _remoteCandidates) {
      try {
        await pc.addCandidate(candidate);
      } catch (error) {
        debugPrint('[MeshTalk] Failed to add remote candidate: $error');
      }
    }
    _remoteCandidates.clear();
  }

  Future<void> _pushCandidate(String node, Map<String, dynamic> candidate) async {
    debugPrint('[MeshTalk] pushing local candidate to $node');
    await _roomRef.child(node).push().set(candidate);
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
    _ensureLocalAudioEnabled();
    // Fire-and-forget with error isolation: a native audio failure (e.g. on
    // Realme C12) must never interrupt or disconnect the WebRTC handshake.
    unawaited(
      _noticeTonePlayer.play().catchError((Object error) {
        debugPrint('Notice tone error ignored: $error');
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