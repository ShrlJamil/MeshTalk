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

  final List<dynamic> _remoteCandidates = [];
  bool _isCaller = false;
  bool _remoteDescriptionSet = false;

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
    _pc = pc;

    pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return;
      _pushCandidate(_isCaller ? 'caller_candidates' : 'callee_candidates', candidate.toMap());
    };

    pc.onTrack = (event) {
      final stream = event.streams.isNotEmpty ? event.streams.first : event.receiver?.track;
      if (stream is MediaStream) {
        onRemoteStream?.call(stream);
      }
    };

    pc.onConnectionState = (state) {
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _setState(SignalingState.connected);
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          _setState(SignalingState.failed);
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          _setState(SignalingState.disconnected);
        default:
          break;
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

  Future<void> startCaller({
    required void Function(MediaStream stream) onRemoteStream,
    required void Function(SignalingState state) onStateChanged,
  }) async {
    this.onRemoteStream = onRemoteStream;
    this.onStateChanged = onStateChanged;
    _isCaller = true;
    _setState(SignalingState.connecting);

    await _roomRef.remove();

    await _createPeerConnection();
    await _getLocalStream();

    final offer = await _pc!.createOffer();
    await _pc!.setLocalDescription(offer);
    await _roomRef.child('offer').set(offer.toMap());

    _answerSub = _roomRef.child('answer').onValue.listen((event) async {
      final data = Map<String, dynamic>.from(event.snapshot.value as Map);
      if (data.isEmpty || _pc == null) return;

      final description = RTCSessionDescription(
        data['sdp'] as String,
        data['type'] as String,
      );
      await _pc!.setRemoteDescription(description);
      _remoteDescriptionSet = true;
      await _flushRemoteCandidates();
      _setState(SignalingState.connected);
    });

    _listenCandidates(
      node: 'callee_candidates',
      subscription: (sub) => _calleeCandidatesSub = sub,
    );
  }

  Future<void> startCallee({
    required void Function(MediaStream stream) onRemoteStream,
    required void Function(SignalingState state) onStateChanged,
  }) async {
    this.onRemoteStream = onRemoteStream;
    this.onStateChanged = onStateChanged;
    _isCaller = false;

    await Helper.setSpeakerphoneOn(true);
    _setState(SignalingState.connecting);

    _offerSub = _roomRef.child('offer').onValue.listen((event) async {
      if (event.snapshot.value == null || _pc != null) return;

      final data = Map<String, dynamic>.from(event.snapshot.value as Map);
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

      _listenCandidates(
        node: 'caller_candidates',
        subscription: (sub) => _callerCandidatesSub = sub,
      );
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
    for (final candidate in _remoteCandidates) {
      await _pc?.addCandidate(candidate as RTCIceCandidate);
    }
    _remoteCandidates.clear();
  }

  Future<void> _pushCandidate(String node, Map<String, dynamic> candidate) async {
    await _roomRef.child(node).push().set(candidate);
  }

  Future<void> hangup() async {
    await _answerSub?.cancel();
    await _offerSub?.cancel();
    await _callerCandidatesSub?.cancel();
    await _calleeCandidatesSub?.cancel();
    _answerSub = null;
    _offerSub = null;
    _callerCandidatesSub = null;
    _calleeCandidatesSub = null;

    await _pc?.close();
    _pc = null;
    _remoteCandidates.clear();
    _isCaller = false;
    _remoteDescriptionSet = false;

    await _localStream?.dispose();
    _localStream = null;

    _setState(SignalingState.idle);
  }

  Future<void> dispose() => hangup();
}
