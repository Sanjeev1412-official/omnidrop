import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'webrtc_manager.dart';

enum TransferState { idle, connecting, transferring, completed, failed }

class TransferEngine {
  final WebRTCManager webrtcManager;
  String myUsername; // mutable so ChatScreen can update after profile load

  final void Function(TransferState state) onStateChanged;
  final void Function(double progress, String speedText) onProgressUpdated;
  final void Function(String fileName, int size) onReceiveStart;
  final void Function(String savedPath) onReceiveComplete;
  final void Function(String text) onTextMessage;
  final void Function(String error) onError;

  // Sending
  File? _sendingFile;
  int _bytesSent = 0;
  int _totalBytesToSend = 0;
  DateTime? _transferStartTime;
  bool _isSending = false;

  // Receiving
  File? _receivingFile;
  IOSink? _fileSink;
  int _bytesReceived = 0;
  int _totalBytesToReceive = 0;
  String? _receivingFileName;

  static const int _chunkSize = 64 * 1024; // 64 KB — safe SCTP limit

  TransferEngine({
    required this.webrtcManager,
    required this.myUsername,
    required this.onStateChanged,
    required this.onProgressUpdated,
    required this.onReceiveStart,
    required this.onReceiveComplete,
    required this.onTextMessage,
    required this.onError,
  });

  void initialize() {
    // ── FIX 1: ADD listener instead of overwriting ────────────────────────
    // Old code: webrtcManager.onDataChannelState = (state) { ... }
    // That wiped ChatScreen's callback → _isWebRtcConnected never flipped.
    // Now we register as an ADDITIONAL listener. Both fire independently.
    webrtcManager.addDataChannelStateListener((state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        onStateChanged(TransferState.idle);
      } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
        onStateChanged(TransferState.idle);
      }
    });
  }

  void handleIncomingMessage(RTCDataChannelMessage message) {
    if (message.isBinary) {
      _handleBinaryChunk(message.binary);
    } else {
      _handleTextPayload(message.text);
    }
  }

  void _handleTextPayload(String text) {
    try {
      final payload = jsonDecode(text) as Map<String, dynamic>;
      final type = payload['type'] as String?;

      switch (type) {
        case 'text_message':
          onTextMessage(payload['text'] as String);
          break;

        case 'file_start':
          _receivingFileName = payload['fileName'] as String;
          _totalBytesToReceive = payload['fileSize'] as int;
          _bytesReceived = 0;
          _transferStartTime = DateTime.now();

          final tempDir = Directory.systemTemp;
          // Sanitize filename to avoid path traversal
          final safeName =
              _receivingFileName!.replaceAll(RegExp(r'[/\\]'), '_');
          _receivingFile = File('${tempDir.path}/$safeName');
          _fileSink = _receivingFile!.openWrite();

          onReceiveStart(_receivingFileName!, _totalBytesToReceive);
          onStateChanged(TransferState.transferring);
          break;

        case 'file_end':
          _finishReceiving();
          break;
      }
    } catch (e) {
      debugPrint('[TransferEngine] Error parsing text message: $e');
    }
  }

  void _handleBinaryChunk(Uint8List chunk) {
    if (_fileSink == null) return;

    _fileSink!.add(chunk);
    _bytesReceived += chunk.length;

    // Throttle UI: update every 1 MB or on last chunk
    if (_bytesReceived % (1024 * 1024) < _chunkSize ||
        _bytesReceived >= _totalBytesToReceive) {
      _updateProgress(_bytesReceived, _totalBytesToReceive);
    }
  }

  Future<void> _finishReceiving() async {
    try {
      await _fileSink?.flush();
      await _fileSink?.close();
    } catch (e) {
      debugPrint('[TransferEngine] Error closing file sink: $e');
    }
    _fileSink = null;

    if (_receivingFile != null && await _receivingFile!.exists()) {
      onReceiveComplete(_receivingFile!.path);
      onStateChanged(TransferState.completed);
    }

    _receivingFile = null;
    _receivingFileName = null;
    _bytesReceived = 0;
    _totalBytesToReceive = 0;
  }

  Future<void> sendTextMessage(String text) async {
    final payload = jsonEncode({'type': 'text_message', 'text': text});
    await webrtcManager.sendData(RTCDataChannelMessage(payload));
  }

  Future<void> sendFile(
      String filePath, String fileName, int fileSize) async {
    if (_isSending) {
      onError('A transfer is already in progress');
      return;
    }

    _isSending = true;
    _sendingFile = File(filePath);
    _totalBytesToSend = fileSize;
    _bytesSent = 0;
    _transferStartTime = DateTime.now();
    onStateChanged(TransferState.transferring);

    try {
      // 1. Metadata header
      await webrtcManager.sendData(RTCDataChannelMessage(jsonEncode({
        'type': 'file_start',
        'fileName': fileName,
        'fileSize': fileSize,
      })));

      // 2. Binary chunks with backpressure
      await for (final chunk
          in _chunkStream(_sendingFile!.openRead(), _chunkSize)) {
        if (!_isSending) break;

        await webrtcManager
            .sendData(RTCDataChannelMessage.fromBinary(Uint8List.fromList(chunk)));
        _bytesSent += chunk.length;

        if (_bytesSent % (1024 * 1024) < _chunkSize ||
            _bytesSent == _totalBytesToSend) {
          _updateProgress(_bytesSent, _totalBytesToSend);
        }

        // Backpressure: Wait if SCTP buffer exceeds 1MB (1024 * 1024 bytes)
        while (webrtcManager.bufferedAmount > 1024 * 1024) {
          if (!_isSending) break;
          await Future.delayed(const Duration(milliseconds: 5));
        }
        
        // Yield to event loop
        await Future.delayed(Duration.zero);
      }

      // 3. EOF marker
      if (_isSending) {
        await webrtcManager.sendData(
            RTCDataChannelMessage(jsonEncode({'type': 'file_end'})));
        onStateChanged(TransferState.completed);
      }
    } catch (e) {
      debugPrint('[TransferEngine] Send error: $e');
      onError('Transfer failed: $e');
      onStateChanged(TransferState.failed);
    } finally {
      _isSending = false;
      _sendingFile = null;
    }
  }

  Stream<List<int>> _chunkStream(Stream<List<int>> source, int size) async* {
    final buffer = <int>[];
    await for (final chunk in source) {
      buffer.addAll(chunk);
      while (buffer.length >= size) {
        yield buffer.sublist(0, size);
        buffer.removeRange(0, size);
      }
    }
    if (buffer.isNotEmpty) yield buffer;
  }

  void _updateProgress(int done, int total) {
    if (total == 0) return;
    final progress = (done / total).clamp(0.0, 1.0);
    final elapsedMs =
        DateTime.now().difference(_transferStartTime!).inMilliseconds;
    String speedText = 'Calculating...';
    if (elapsedMs > 500) {
      final mbps = (done / (elapsedMs / 1000)) / (1024 * 1024);
      speedText = '${mbps.toStringAsFixed(1)} MB/s';
    }
    onProgressUpdated(progress, speedText);
  }

  Future<void> cancelTransfer() async {
    _isSending = false;
    await _finishReceiving();
    onStateChanged(TransferState.idle);
  }
}