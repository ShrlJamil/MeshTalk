import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

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

  final DatabaseReference _database;

  RTCPeerConnection? _pc;
  MediaStream? _localStream;

  final List<RTCIceCandidate> _remoteCandidates = [];
  bool _isCaller = false;
  bool _remoteDescriptionSet = false;
  bool _handled = false;

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
    final pc = await createPeerConnection(_iceConfiguration);
    final session = _sessionId;
    _pc = pc;

    pc.onIceCandidate = (candidate) {
      if (session != _sessionId) return;
      if (candidate.candidate == null) return;
      _pushCandidate(
        _isCaller ? 'caller_candidates' : 'callee_candidates',
        candidate.toMap(),
      );
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
      if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateClosed ||
          state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        _handlePeerDisconnected();
      }
    };

    return pc;
  }

  Future<MediaStream> _getLocalStream() async {
    final stream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': false,
    });
    _localStream = stream;
    for (final track in stream.getAudioTracks()) {
      await _pc?.addTrack(track, stream);
    }
    return stream;
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
  }

  /// Cleans the whole room (Firebase node + local WebRTC state) before
  /// starting a fresh handshake so no stale offer/answer/candidate is reused.
  Future<void> cleanupRoom() async {
    _sessionId++;
    await _cancelSubscriptions();
    await _closePeerConnection();
    await _roomRef.remove();
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

    final session = ++_sessionId;

    await _createPeerConnection();
    await _getLocalStream();

    final offer = await _pc!.createOffer();
    await _pc!.setLocalDescription(offer);
    await _roomRef.child('offer').set({
      ...offer.toMap(),
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    });

    // Register the callee candidate listener early so candidates arriving
    // before the answer is processed are buffered, not lost.
    _listenCandidates(
      node: 'callee_candidates',
      subscription: (sub) => _calleeCandidatesSub = sub,
    );

    _answerSub = _roomRef.child('answer').onValue.listen((event) async {
      if (session != _sessionId) return;
      if (_remoteDescriptionSet || _pc == null) return;

      final value = event.snapshot.value;
      if (value == null) return;
      final data = Map<String, dynamic>.from(value as Map);
      if (data.isEmpty) return;

      final description = RTCSessionDescription(
        data['sdp'] as String,
        data['type'] as String,
      );
      await _pc!.setRemoteDescription(description);
      _remoteDescriptionSet = true;
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

    await Helper.setSpeakerphoneOn(true);
    _setState(SignalingState.connecting);

    final session = ++_sessionId;

    // Register the caller candidate listener early so no candidate is missed
    // while we wait for the offer. Candidates are buffered until the remote
    // description is set.
    _listenCandidates(
      node: 'caller_candidates',
      subscription: (sub) => _callerCandidatesSub = sub,
    );

    _offerSub = _roomRef.child('offer').onValue.listen((event) async {
      if (session != _sessionId) return;

      final value = event.snapshot.value;
      if (value == null) {
        // The Caller removed the room (hangup / cleanup) while we were in an
        // active call: tear down and re-enter standby automatically.
        if (_handled && _pc != null) {
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
        return;
      }

      if (_handled || _pc != null) return;
      _handled = true;

      final offer = RTCSessionDescription(
        data['sdp'] as String,
        data['type'] as String,
      );

      await _createPeerConnection();
      await _getLocalStream();
      await _pc!.setRemoteDescription(offer);
      _remoteDescriptionSet = true;

      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);
      await _roomRef.child('answer').set(answer.toMap());

      await _flushRemoteCandidates();
      _setState(SignalingState.connected);
    });
  }

  void _listenCandidates({
    required String node,
    required void Function(StreamSubscription<DatabaseEvent>) subscription,
  }) {
    subscription(_roomRef.child(node).onChildAdded.listen((event) async {
      if (event.snapshot.value == null || _pc == null) return;

      final data = Map<String, dynamic>.from(event.snapshot.value as Map);
      final candidate = RTCIceCandidate(
        data['candidate'] as String,
        data['sdpMid'] as String?,
        int.parse(data['sdpMLineIndex'].toString()),
      );

      if (_remoteDescriptionSet) {
        await _pc!.addCandidate(candidate);
      } else {
        _remoteCandidates.add(candidate);
      }
    }));
  }

  Future<void> _flushRemoteCandidates() async {
    final pc = _pc;
    if (pc == null) {
      _remoteCandidates.clear();
      return;
    }
    for (final candidate in _remoteCandidates) {
      await pc.addCandidate(candidate);
    }
    _remoteCandidates.clear();
  }

  Future<void> _pushCandidate(String node, Map<String, dynamic> candidate) async {
    await _roomRef.child(node).push().set(candidate);
  }

  /// Network-level disconnection (ICE or RTCPeerConnection) detected on the
  /// Callee while a call is active.
  void _handlePeerDisconnected() {
    if (_isCaller || !_handled || _pc == null) return;
    _onCallEndedByRemote();
  }

  /// The remote peer ended the call (caller hangup / network drop). Callee
  /// cleans up all resources and automatically re-enters standby mode.
  Future<void> _onCallEndedByRemote() async {
    if (_autoResetting) return;
    _autoResetting = true;
    try {
      if (_isCaller) {
        await hangup();
        return;
      }

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
    await cleanupRoom();
    _setState(SignalingState.idle);
  }

  Future<void> dispose() => hangup();
}