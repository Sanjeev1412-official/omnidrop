import 'dart:async';
import 'dart:convert';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter/foundation.dart';

typedef SignalingSendCallback = void Function(String message);
typedef DataChannelStateCallback = void Function(RTCDataChannelState state);
typedef DataChannelMessageCallback = void Function(RTCDataChannelMessage message);

class WebRTCManager {
  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;

  // ── FIX 1: list of listeners instead of single callback ──────────────────
  // TransferEngine was overwriting ChatScreen's callback with a single field.
  // Now every subscriber adds itself; none clobbers another.
  final List<DataChannelStateCallback> _stateListeners = [];

  SignalingSendCallback? onSignalingMessage;
  DataChannelMessageCallback? onDataChannelMessage;

  // ── FIX 2: ICE candidate queue ────────────────────────────────────────────
  // Candidates arriving before setRemoteDescription were silently dropped,
  // causing connection failure especially on the answerer side.
  final List<RTCIceCandidate> _pendingCandidates = [];
  bool _remoteDescriptionSet = false;

  bool _isOfferer = false;
  bool _isDisposed = false;

  // ── Backward-compat setter: replaces all listeners (ChatScreen uses ctor) ─
  set onDataChannelState(DataChannelStateCallback? cb) {
    _stateListeners.clear();
    if (cb != null) _stateListeners.add(cb);
  }

  /// TransferEngine and any other internal component uses this
  /// so they ADD to listeners instead of wiping them.
  void addDataChannelStateListener(DataChannelStateCallback cb) {
    _stateListeners.add(cb);
  }

  void _notifyState(RTCDataChannelState state) {
    if (_isDisposed) return;
    for (final cb in List.of(_stateListeners)) {
      cb(state);
    }
  }

  WebRTCManager({
    this.onSignalingMessage,
    DataChannelStateCallback? onDataChannelState,
    this.onDataChannelMessage,
  }) {
    if (onDataChannelState != null) _stateListeners.add(onDataChannelState);
  }

  /// Re-entrant safe: calling initialize() again disposes the old connection first.
  Future<void> initialize({required bool isOfferer}) async {
    _isOfferer = isOfferer;
    _isDisposed = false;
    _remoteDescriptionSet = false;
    _pendingCandidates.clear();

    // Clean up previous session without wiping listeners
    await _dataChannel?.close();
    await _peerConnection?.close();
    _dataChannel = null;
    _peerConnection = null;

    final configuration = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        {'urls': 'stun:stun1.l.google.com:19302'},
        {'urls': 'stun:stun2.l.google.com:19302'},
        // TURN fallback for symmetric NAT (replace with own server in production)
        {
          'urls': 'turn:openrelay.metered.ca:80',
          'username': 'openrelayproject',
          'credential': 'openrelayproject',
        },
        {
          'urls': 'turn:openrelay.metered.ca:443',
          'username': 'openrelayproject',
          'credential': 'openrelayproject',
        },
        {
          'urls': 'turn:openrelay.metered.ca:443?transport=tcp',
          'username': 'openrelayproject',
          'credential': 'openrelayproject',
        },
      ],
      'sdpSemantics': 'unified-plan',
      'iceCandidatePoolSize': 10,
    };

    _peerConnection = await createPeerConnection(configuration);

    _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
      if (_isDisposed) return;
      // Empty candidate string = end-of-candidates signal, skip it
      if (candidate.candidate == null || candidate.candidate!.isEmpty) return;
      final payload = {
        'type': 'candidate',
        'candidate': candidate.toMap(),
      };
      onSignalingMessage?.call(jsonEncode(payload));
    };

    _peerConnection!.onConnectionState = (RTCPeerConnectionState state) {
      debugPrint('[WebRTC] Connection state: $state');
    };

    _peerConnection!.onIceConnectionState = (RTCIceConnectionState state) {
      debugPrint('[WebRTC] ICE Connection state: $state');
    };

    if (isOfferer) {
      // Offerer creates data channel BEFORE offer so it's included in SDP
      await _createDataChannel();

      final offer = await _peerConnection!.createOffer();
      await _peerConnection!.setLocalDescription(offer);

      onSignalingMessage?.call(jsonEncode({
        'type': 'offer',
        'sdp': offer.sdp,
      }));
    } else {
      // Answerer receives the data channel created by offerer via onDataChannel
      _peerConnection!.onDataChannel = (RTCDataChannel channel) {
        debugPrint('[WebRTC] onDataChannel received (answerer)');
        _dataChannel = channel;
        _setupDataChannelListeners();
      };
    }
  }

  Future<void> _createDataChannel() async {
    if (_peerConnection == null) return;

    final init = RTCDataChannelInit()
      ..ordered = true
      ..protocol = 'sctp';

    _dataChannel = await _peerConnection!.createDataChannel(
      'omnidrop_transfer',
      init,
    );

    _setupDataChannelListeners();
  }

  void _setupDataChannelListeners() {
    if (_dataChannel == null) return;

    _dataChannel!.onDataChannelState = (RTCDataChannelState state) {
      debugPrint('[WebRTC] Data channel state: $state');
      _notifyState(state); // Fires ALL registered listeners
    };

    _dataChannel!.onMessage = (RTCDataChannelMessage message) {
      if (!_isDisposed) onDataChannelMessage?.call(message);
    };
  }

  Future<void> handleSignalingMessage(String jsonStr) async {
    if (_peerConnection == null || _isDisposed) return;

    try {
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      final type = data['type'] as String?;

      if (type == 'offer' && !_isOfferer) {
        await _peerConnection!
            .setRemoteDescription(RTCSessionDescription(data['sdp'], 'offer'));
        _remoteDescriptionSet = true;
        await _flushPendingCandidates();

        final answer = await _peerConnection!.createAnswer();
        await _peerConnection!.setLocalDescription(answer);

        onSignalingMessage?.call(jsonEncode({
          'type': 'answer',
          'sdp': answer.sdp,
        }));
      } else if (type == 'answer' && _isOfferer) {
        await _peerConnection!.setRemoteDescription(
            RTCSessionDescription(data['sdp'], 'answer'));
        _remoteDescriptionSet = true;
        await _flushPendingCandidates();
      } else if (type == 'candidate') {
        final cd = data['candidate'] as Map<String, dynamic>;
        final candidate = RTCIceCandidate(
          cd['candidate'] as String,
          cd['sdpMid'] as String?,
          cd['sdpMLineIndex'] as int?,
        );

        if (_remoteDescriptionSet) {
          await _peerConnection!.addCandidate(candidate);
        } else {
          // ── FIX 2: queue instead of drop ──────────────────────────────────
          _pendingCandidates.add(candidate);
          debugPrint(
              '[WebRTC] ICE candidate queued (remote desc not set yet). Queue size: ${_pendingCandidates.length}');
        }
      }
    } catch (e) {
      debugPrint('[WebRTC] handleSignalingMessage error: $e');
    }
  }

  Future<void> _flushPendingCandidates() async {
    debugPrint(
        '[WebRTC] Flushing ${_pendingCandidates.length} queued ICE candidates');
    for (final c in _pendingCandidates) {
      try {
        await _peerConnection!.addCandidate(c);
      } catch (e) {
        debugPrint('[WebRTC] Failed to add queued candidate: $e');
      }
    }
    _pendingCandidates.clear();
  }

  Future<void> sendData(RTCDataChannelMessage message) async {
    if (_dataChannel == null) {
      throw Exception('Data channel is null');
    }
    if (_dataChannel!.state != RTCDataChannelState.RTCDataChannelOpen) {
      throw Exception(
          'Data channel not open. State: ${_dataChannel!.state}');
    }
    await _dataChannel!.send(message);
  }

  RTCDataChannelState? get dataChannelState => _dataChannel?.state;
  int get bufferedAmount => _dataChannel?.bufferedAmount ?? 0;

  Future<void> dispose() async {
    _isDisposed = true;
    _pendingCandidates.clear();
    await _dataChannel?.close();
    await _peerConnection?.close();
    _dataChannel = null;
    _peerConnection = null;
  }
}
