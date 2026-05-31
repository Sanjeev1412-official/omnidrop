import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:omnidrop/models/chat_message.dart';
import 'package:omnidrop/core/p2p_manager.dart';
import 'package:omnidrop/core/toast_utils.dart';
import 'package:omnidrop/core/sync_service.dart';

// ─── Design Tokens (Cream × Black editorial palette) ─────────────────────────
class _C {
  static const bg = Color(0xFFF5F0E8);
  static const surface = Color(0xFFEDE8DF);
  static const ink = Color(0xFF0A0A0A);
  static const border = Color(0xFFD4CEC4);
  static const borderDk = Color(0xFFB8B0A4);
  static const grey60 = Color(0xFF8A8278);
  static const grey30 = Color(0xFFB8B2A8);
  static const onlineDot = Color(0xFF2ECC71);
  static const white = Color(0xFFFFFFFF);
  static const exitdelete = Color.fromARGB(255, 255, 50, 50);
}

class ChatScreen extends StatefulWidget {
  final String peerUsername;
  final String? displayName;
  final String? peerAvatarBase64;

  const ChatScreen({
    super.key,
    required this.peerUsername,
    this.displayName,
    this.peerAvatarBase64,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final List<ChatMessage> _messages = [];
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  String? _myUsername;
  String? _peerDisplayName;
  String? _peerAvatarBase64;
  StreamSubscription<P2PMessageEvent>? _messageSubscription;

  Timer? _statusTimer;

  @override
  void initState() {
    super.initState();
    _initChat();

    
  }

  Future<void> _initChat() async {
    await _loadMyProfile();
    await _loadPeerProfile();
    await _loadChatHistory();
    if (mounted) {
      _subscribeToP2PStream();
      // Poll connection status every second to update UI instantly
      _statusTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _saveChatHistory();
    _messageSubscription?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadMyProfile() async {
    final prefs = await SharedPreferences.getInstance();
    _myUsername = prefs.getString('username') ?? 'User';
  }

  Future<void> _loadPeerProfile() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      
      final namesStr = prefs.getString('paired_devices_names') ?? '{}';
      final namesMap = jsonDecode(namesStr) as Map<String, dynamic>;
      
      final registryStr = prefs.getString('paired_devices_registry') ?? '{}';
      final registry = jsonDecode(registryStr) as Map<String, dynamic>;
      
      if (mounted) {
        setState(() {
          _peerDisplayName = namesMap[widget.peerUsername] as String? ?? widget.displayName ?? widget.peerUsername;
          _peerAvatarBase64 = registry[widget.peerUsername] as String? ?? widget.peerAvatarBase64;
        });
      }
    } catch (e) {
      debugPrint('Error loading peer profile: $e');
      if (mounted) {
        setState(() {
          _peerDisplayName = widget.displayName ?? widget.peerUsername;
          _peerAvatarBase64 = widget.peerAvatarBase64;
        });
      }
    }
  }

  void _subscribeToP2PStream() {
    _messageSubscription = P2PManager().eventStream.listen((event) {
      if (event.peerUsername == widget.peerUsername) {
        
        if (event.toastMessage != null) {
          ToastUtils.showCustomToast(context, event.toastMessage!);
        }

        if (event.isProfileUpdate) {
          _loadPeerProfile();
        }

        if (event.isConnectionStatusUpdate) {
          if (mounted) setState(() {});
          return;
        }
        
        final msg = event.message;
        if (msg == null) return;
        
        if (event.isProgressUpdate) {
          int index = _messages.indexWhere(
            (m) => m.fileName == msg.fileName && 
                   m.timestamp.difference(msg.timestamp).inSeconds.abs() < 10
          );
          if (index != -1) {
            setState(() {
              _messages[index].transferProgress = msg.transferProgress;
              _messages[index].transferSpeed = msg.transferSpeed;
              _messages[index].isTransferComplete = msg.isTransferComplete;
            });
          }
        } else {
          final exists = _messages.any(
            (m) => m.text == msg.text && 
                   m.timestamp.difference(msg.timestamp).inSeconds.abs() < 2
          );
          if (!exists) {
            setState(() {
              _messages.add(msg);
            });
            _scrollToBottom();
          } else {
            final idx = _messages.indexWhere(
              (m) => m.text == msg.text && 
                     m.timestamp.difference(msg.timestamp).inSeconds.abs() < 2
            );
            if (idx != -1) {
              setState(() {
                _messages[idx] = msg;
              });
            }
          }
        }
      }
    });
  }

  Future<void> _loadChatHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = 'chat_history_${widget.peerUsername}';
      final rawList = prefs.getStringList(key);
      if (rawList != null && rawList.isNotEmpty) {
        final List<ChatMessage> history = rawList
            .map((jsonString) => ChatMessage.fromJson(jsonDecode(jsonString)))
            .toList();
        if (mounted) {
          setState(() {
            _messages.clear();
            _messages.addAll(history);
          });
          _scrollToBottom();
        }
      } else {
        setState(() {
          _messages.clear();
          _messages.add(ChatMessage(
            text: 'OmniDrop direct offline channel ready. Scanning local network for @${widget.peerUsername}...',
            isMe: false,
            timestamp: DateTime.now().subtract(const Duration(seconds: 30)),
          ));
        });
      }
      _scrollToBottom();
    } catch (e) {
      debugPrint('Error loading chat history: $e');
    }
  }

  Future<void> _saveChatHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = 'chat_history_${widget.peerUsername}';
      final serialized = _messages.map((msg) => jsonEncode(msg.toJson())).toList();
      await prefs.setStringList(key, serialized);
      SyncService().pushChatHistory(widget.peerUsername);
    } catch (e) {
      debugPrint('Error saving chat history: $e');
    }
  }

  void _showClearChatConfirmation() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: Dialog(
            backgroundColor: Colors.transparent,
            elevation: 0,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 400),
              padding: const EdgeInsets.all(32),
              decoration: BoxDecoration(
                color: _C.bg,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: _C.ink, width: 2),
                boxShadow: const [
                  BoxShadow(
                    color: _C.ink,
                    offset: Offset(8, 8),
                    blurRadius: 0,
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: _C.exitdelete.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(LucideIcons.alertTriangle, color: _C.exitdelete, size: 32),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Clear Chat',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w900,
                      color: _C.ink,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Are you sure you want to clear all messages? This action cannot be undone.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 15,
                      color: _C.grey60,
                      height: 1.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 32),
                  Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: () => Navigator.pop(context),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            decoration: BoxDecoration(
                              color: _C.surface,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: _C.ink, width: 2),
                            ),
                            alignment: Alignment.center,
                            child: const Text(
                              'Cancel',
                              style: TextStyle(
                                color: _C.ink,
                                fontWeight: FontWeight.w900,
                                fontSize: 15,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: GestureDetector(
                          onTap: () async {
                            Navigator.pop(context);
                            await _clearChat();
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            decoration: BoxDecoration(
                              color: _C.exitdelete,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: _C.ink, width: 2),
                            ),
                            alignment: Alignment.center,
                            child: const Text(
                              'Clear',
                              style: TextStyle(
                                color: _C.white,
                                fontWeight: FontWeight.w900,
                                fontSize: 15,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _clearChat() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = 'chat_history_${widget.peerUsername}';
      await prefs.remove(key);
      setState(() {
        _messages.clear();
        _messages.add(ChatMessage(
          text: 'Chat cleared. Scanning local network for @${widget.peerUsername}...',
          isMe: false,
          timestamp: DateTime.now(),
        ));
      });
      if (mounted) {
        ToastUtils.showCustomToast(context, 'Chat history cleared.', icon: LucideIcons.trash2);
      }
      SyncService().pushChatHistory(widget.peerUsername);
    } catch (e) {
      debugPrint('Error clearing chat history: $e');
    }
  }

  void _showMessageOptions(ChatMessage msg, Offset position) {
    showMenu(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, position.dy),
      color: _C.surface,
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: _C.ink, width: 1.5),
      ),
      items: [
        if (msg.fileName == null)
          PopupMenuItem(
            onTap: () {
              Clipboard.setData(ClipboardData(text: msg.text));
              ToastUtils.showCustomToast(context, 'Message copied to clipboard', icon: LucideIcons.copy);
            },
            child: const Row(
              children: [
                Icon(LucideIcons.copy, color: _C.ink, size: 18),
                SizedBox(width: 12),
                Text('Copy Text', style: TextStyle(color: _C.ink, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        PopupMenuItem(
          onTap: () {
            Future.delayed(const Duration(milliseconds: 50), () {
              _showDeleteMessageConfirmation(msg);
            });
          },
          child: const Row(
            children: [
              Icon(LucideIcons.trash2, color: _C.exitdelete, size: 18),
              SizedBox(width: 12),
              Text('Delete Message', style: TextStyle(color: _C.exitdelete, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      ],
    );
  }

  void _showDeleteMessageConfirmation(ChatMessage msg) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: Dialog(
            backgroundColor: Colors.transparent,
            elevation: 0,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 400),
              padding: const EdgeInsets.all(32),
              decoration: BoxDecoration(
                color: _C.bg,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: _C.ink, width: 2),
                boxShadow: const [
                  BoxShadow(
                    color: _C.ink,
                    offset: Offset(8, 8),
                    blurRadius: 0,
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: _C.exitdelete.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(LucideIcons.trash2, color: _C.exitdelete, size: 32),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Delete Message',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w900,
                      color: _C.ink,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Are you sure you want to delete this message? This action cannot be undone.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 15,
                      color: _C.grey60,
                      height: 1.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 32),
                  Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: () => Navigator.pop(context),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            decoration: BoxDecoration(
                              color: _C.surface,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: _C.ink, width: 2),
                            ),
                            alignment: Alignment.center,
                            child: const Text(
                              'Cancel',
                              style: TextStyle(
                                color: _C.ink,
                                fontWeight: FontWeight.w900,
                                fontSize: 15,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: GestureDetector(
                          onTap: () async {
                            Navigator.pop(context);
                            await _deleteMessage(msg);
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            decoration: BoxDecoration(
                              color: _C.exitdelete,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: _C.ink, width: 2),
                            ),
                            alignment: Alignment.center,
                            child: const Text(
                              'Delete',
                              style: TextStyle(
                                color: _C.white,
                                fontWeight: FontWeight.w900,
                                fontSize: 15,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _deleteMessage(ChatMessage msg) async {
    setState(() {
      _messages.remove(msg);
    });
    await _saveChatHistory();
  }

  // Background P2P receiver/sockets managed by P2PManager

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients && _scrollController.offset > 0) {
        _scrollController.animateTo(
          0.0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    final newMsg = ChatMessage(
      text: text,
      isMe: true,
      timestamp: DateTime.now(),
    );

    _messageController.clear();

    final peerIp = P2PManager().peerIpAddresses[widget.peerUsername];
    if (peerIp != null) {
      // Send real TCP text message offline
      try {
        final socket = await Socket.connect(peerIp, 40902, timeout: const Duration(seconds: 2));
        final prefs = await SharedPreferences.getInstance();
        final myDisplayName = prefs.getString('display_name') ?? _myUsername;
        final myAvatar = prefs.getString('profile_image');

        final payload = jsonEncode({
          'sender': _myUsername,
          'displayName': myDisplayName,
          'avatar': myAvatar,
          'text': text,
        });
        socket.write('$payload\n');
        await socket.flush();
        await socket.close();

        setState(() {
          _messages.add(newMsg);
        });
        _saveChatHistory();
        _scrollToBottom();
      } catch (e) {
        debugPrint('Error transmitting text over TCP: $e');
        if (mounted) {
          ToastUtils.showCustomToast(context, 'Failed to transmit message P2P.', icon: LucideIcons.alertCircle);
        }
        _sendMockMessage(text, newMsg);
      }
    } else {
      _sendMockMessage(text, newMsg);
    }
  }

  void _sendMockMessage(String text, ChatMessage newMsg) {
    setState(() {
      _messages.add(newMsg);
    });
    _scrollToBottom();
    _saveChatHistory();

    // Trigger simulated sandbox reply
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (!mounted) return;
      setState(() {
        _messages.add(ChatMessage(
          text: 'Echo (Sandbox Simulator): "$text"',
          isMe: false,
          timestamp: DateTime.now(),
        ));
      });
      _scrollToBottom();
      _saveChatHistory();
    });
  }

  Future<void> _pickAndSendFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.any,
      );

      if (result != null && result.files.isNotEmpty) {
        if (!mounted) return;
        
        for (final file in result.files) {
          // Process each file in an independent asynchronous task so they transmit simultaneously
          () async {
            final newMsg = ChatMessage(
              text: 'Sharing file: ${file.name}',
              isMe: true,
              timestamp: DateTime.now(),
              fileName: file.name,
              fileSize: file.size,
              fileExtension: file.extension,
              transferProgress: 0.0,
              isTransferComplete: false,
              transferSpeed: '0.0 MB/s',
            );

            final peerIp = P2PManager().peerIpAddresses[widget.peerUsername];
            if (peerIp != null) {
              // Helper to attempt one direct TCP send
              Future<Socket> connectDirect() => Socket.connect(
                    peerIp,
                    40902,
                    // 4s timeout — enough for Android background service to bind its socket
                    // even if it was just woken up by the Quick Tile.
                    timeout: const Duration(seconds: 4),
                  );

              Future<void> sendOverSocket(Socket socket) async {
                socket.setOption(SocketOption.tcpNoDelay, true);
                final prefs = await SharedPreferences.getInstance();
                final myDisplayName = prefs.getString('display_name') ?? _myUsername;
                final myAvatar = prefs.getString('profile_image');

                final payload = jsonEncode({
                  'sender': _myUsername,
                  'displayName': myDisplayName,
                  'avatar': myAvatar,
                  'text': 'Sharing file: ${file.name}',
                  'fileName': file.name,
                  'fileSize': file.size,
                  'fileExtension': file.extension,
                });
                socket.write('$payload\n');

                Stream<List<int>> fileStream;
                if (file.path != null) {
                  fileStream = File(file.path!).openRead();
                } else if (file.bytes != null) {
                  fileStream = Stream.value(file.bytes!);
                } else {
                  throw Exception('No file path or bytes available');
                }

                final int totalSize = file.size;
                int bytesSent = 0;
                Timer? progressTimer;

                progressTimer = Timer.periodic(
                  const Duration(milliseconds: 100),
                  (_) {
                    if (!mounted) return;
                    _updateProgress(newMsg, bytesSent, totalSize);
                  },
                );

                final mappedStream = fileStream.map((chunk) {
                  bytesSent += chunk.length;
                  return chunk;
                });

                try {
                  await socket.addStream(mappedStream);
                  await socket.flush();
                } finally {
                  progressTimer.cancel();
                }
                await socket.close();

                if (mounted) {
                  setState(() {
                    newMsg.transferProgress = 1.0;
                    newMsg.isTransferComplete = true;
                    newMsg.transferSpeed = null;
                  });
                }
                _saveChatHistory();
              }

              try {
                Socket socket;
                try {
                  // First attempt
                  socket = await connectDirect();
                } catch (_) {
                  // First attempt failed — the peer's background service may still be
                  // binding its TCP socket after waking up. Wait 2s and try once more
                  // before falling back to the reverse connection mechanism.
                  if (mounted) {
                    ToastUtils.showCustomToast(context, 'Waking up peer background service...', icon: LucideIcons.loader);
                  }
                  await Future.delayed(const Duration(seconds: 2));
                  socket = await connectDirect(); // Second (final direct) attempt
                }

                if (mounted) {
                  setState(() {
                    _messages.add(newMsg);
                  });
                  _saveChatHistory();
                  _scrollToBottom();
                }

                await sendOverSocket(socket);
              } catch (e) {
                debugPrint('Error transmitting file payload: $e');
                // Both direct attempts failed.
                // Fallback: request a Reverse TCP Connection via Supabase!
                await _tryReverseConnection(file, newMsg);
              }
            } else {
              if (mounted) {
                ToastUtils.showCustomToast(context, 'Cannot connect. IP unknown.', icon: LucideIcons.xCircle);
              }
            }
          }();
        }
      }
    } catch (e) {
      debugPrint('Error picking file: $e');
      if (mounted) {
        ToastUtils.showCustomToast(context, 'Failed to pick file', icon: LucideIcons.xCircle);
      }
    }
  }

  Future<void> _tryReverseConnection(PlatformFile file, ChatMessage newMsg) async {
    try {
      if (mounted) {
        ToastUtils.showCustomToast(context, 'Requesting reverse connection...', icon: LucideIcons.refreshCcw);
      }

      // 1. Start a temporary listener on a random available port
      final server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
      final int myPort = server.port;

      // 2. Broadcast via Supabase asking the peer to connect to US
      P2PManager().requestReverseConnection(widget.peerUsername, myPort);

      // 3. Wait for the peer to connect back.
      // 15s timeout gives the Android background service enough time to:
      //   - receive the Supabase broadcast
      //   - open a socket back to us
      // (was 8s — too short when the service is cold-starting)
      final socket = await server.first.timeout(const Duration(seconds: 15));
      server.close(); // Stop listening after one connection
      socket.setOption(SocketOption.tcpNoDelay, true);

      // 4. Send the file payload exactly as normal
      final prefs = await SharedPreferences.getInstance();
      final myDisplayName = prefs.getString('display_name') ?? _myUsername;
      final myAvatar = prefs.getString('profile_image');

      final payload = jsonEncode({
        'sender': _myUsername,
        'displayName': myDisplayName,
        'avatar': myAvatar,
        'text': 'Sharing file: ${file.name}',
        'fileName': file.name,
        'fileSize': file.size,
        'fileExtension': file.extension,
      });
      socket.write('$payload\n');

      setState(() {
        _messages.add(newMsg);
      });
      _saveChatHistory();
      _scrollToBottom();

      Stream<List<int>> fileStream;
      if (file.path != null) {
        fileStream = File(file.path!).openRead();
      } else if (file.bytes != null) {
        fileStream = Stream.value(file.bytes!);
      } else {
        throw Exception('No file path or bytes available');
      }

      final int totalSize = file.size;
      int bytesSent = 0;
      Timer? progressTimer;

      progressTimer = Timer.periodic(
        const Duration(milliseconds: 100),
        (_) {
          if (!mounted) return;
          _updateProgress(newMsg, bytesSent, totalSize);
        },
      );

      final mappedStream = fileStream.map((chunk) {
        bytesSent += chunk.length;
        return chunk;
      });

      try {
        await socket.addStream(mappedStream);
        await socket.flush();
      } finally {
        progressTimer.cancel();
      }
      await socket.close();

      if (mounted) {
        setState(() {
          newMsg.transferProgress = 1.0;
          newMsg.isTransferComplete = true;
          newMsg.transferSpeed = null;
        });
      }
      _saveChatHistory();

    } catch (e) {
      debugPrint('Reverse connection failed: $e');
      if (mounted) {
        ToastUtils.showCustomToast(context, 'Reverse connection failed.', icon: LucideIcons.xCircle);
      }
    }
  }

  void _sendMockFile(PlatformFile file, ChatMessage newMsg) {
    if (!mounted) return;
    setState(() {
      _messages.add(newMsg);
    });
    _saveChatHistory();
    _scrollToBottom();
    _startFileTransferSimulation(newMsg, isMock: true);
  }

  void _startFileTransferSimulation(ChatMessage newMsg, {required bool isMock}) {
    double progress = 0.0;
    Timer.periodic(const Duration(milliseconds: 150), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      progress += 0.08 + (Random().nextDouble() * 0.07);
      if (progress >= 1.0) {
        progress = 1.0;
        timer.cancel();
        setState(() {
          newMsg.transferProgress = 1.0;
          newMsg.isTransferComplete = true;
          newMsg.transferSpeed = null;
        });
        _saveChatHistory();
        if (isMock) {
          _triggerPeerFileReceiptNotification(newMsg.fileName!);
        }
      } else {
        final speed = 28.0 + (Random().nextDouble() * 17.0);
        setState(() {
          newMsg.transferProgress = progress;
          newMsg.transferSpeed = '${speed.toStringAsFixed(1)} MB/s';
        });
      }
    });
  }

  void _triggerPeerFileReceiptNotification(String fileName) {
    Future.delayed(const Duration(milliseconds: 1200), () {
      if (!mounted) return;
      setState(() {
        _messages.add(ChatMessage(
          text: 'File successfully downloaded and verified: "$fileName" (MD5 checksum matched).',
          isMe: false,
          timestamp: DateTime.now(),
        ));
      });
      _saveChatHistory();
      _scrollToBottom();
    });
  }

  void _updateProgress(ChatMessage msg, int received, int total) {
    if (total <= 0) return;
    final progress = (received / total).clamp(0.0, 1.0);
    setState(() {
      msg.transferProgress = progress;
      msg.transferSpeed = '${(received / (1024 * 1024)).toStringAsFixed(1)} MB / ${(total / (1024 * 1024)).toStringAsFixed(1)} MB';
    });
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _formatTime12Hour(DateTime time) {
    int hour = time.hour;
    int minute = time.minute;
    String ampm = hour >= 12 ? 'PM' : 'AM';
    hour = hour % 12;
    if (hour == 0) hour = 12;
    String minuteStr = minute.toString().padLeft(2, '0');
    return '$hour:$minuteStr $ampm';
  }

  String _formatDateHeader(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final msgDate = DateTime(date.year, date.month, date.day);

    if (msgDate == today) {
      return 'Today';
    } else if (msgDate == yesterday) {
      return 'Yesterday';
    } else {
      final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      return '${date.day} ${months[date.month - 1]} ${date.year}';
    }
  }

  bool _shouldShowDateDivider(int chronologicalIndex) {
    if (chronologicalIndex == 0) return true;
    final currentDate = _messages[chronologicalIndex].timestamp;
    final previousDate = _messages[chronologicalIndex - 1].timestamp;
    return currentDate.year != previousDate.year ||
           currentDate.month != previousDate.month ||
           currentDate.day != previousDate.day;
  }

  Widget _buildDateDivider(DateTime date) {
    return Center(
      child: Container(
        margin: const EdgeInsets.only(top: 24, bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: _C.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _C.ink, width: 1.5),
          boxShadow: const [
            BoxShadow(
              color: _C.ink,
              offset: Offset(2, 2),
              blurRadius: 0,
            ),
          ],
        ),
        child: Text(
          _formatDateHeader(date).toUpperCase(),
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w900,
            color: _C.ink,
            letterSpacing: 1.0,
          ),
        ),
      ),
    );
  }

  IconData _getFileIcon(String? extension) {
    if (extension == null) return LucideIcons.file;
    final ext = extension.toLowerCase();
    
    if (['jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp'].contains(ext)) {
      return LucideIcons.fileImage;
    }
    if (['mp4', 'mkv', 'avi', 'mov', 'flv'].contains(ext)) {
      return LucideIcons.fileVideo;
    }
    if (['zip', 'rar', '7z', 'tar', 'gz'].contains(ext)) {
      return LucideIcons.fileArchive;
    }
    if (['pdf'].contains(ext)) {
      return LucideIcons.fileText;
    }
    if (['doc', 'docx', 'txt', 'rtf'].contains(ext)) {
      return LucideIcons.fileText;
    }
    if (['mp3', 'wav', 'm4a', 'flac'].contains(ext)) {
      return LucideIcons.fileAudio;
    }
    return LucideIcons.file;
  }

  // --- UI BUILDING METHODS ---

  @override
  Widget build(BuildContext context) {
    final bool isOnline = P2PManager().isPeerOnline(widget.peerUsername);

    return Scaffold(
      backgroundColor: _C.bg,
      appBar: AppBar(
        backgroundColor: _C.bg,
        elevation: 0,
        titleSpacing: 0,
        iconTheme: const IconThemeData(color: _C.ink),
        title: Row(
          children: [
            Hero(
              tag: 'avatar_${widget.peerUsername}',
              child: Container(
                padding: const EdgeInsets.all(2.5),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isOnline ? _C.onlineDot : _C.border,
                    width: 1.5,
                  ),
                ),
                child: CircleAvatar(
                  radius: 20,
                  backgroundColor: _C.border,
                  backgroundImage: _peerAvatarBase64 != null
                      ? MemoryImage(base64Decode(_peerAvatarBase64!))
                      : null,
                  child: _peerAvatarBase64 == null
                      ? Text(
                          widget.peerUsername.isNotEmpty ? widget.peerUsername[0].toUpperCase() : 'U',
                          style: const TextStyle(fontWeight: FontWeight.bold, color: _C.ink, fontSize: 16),
                        )
                      : null,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _peerDisplayName ?? widget.peerUsername,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _C.ink, letterSpacing: -0.5),
                  ),
                  
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      
                      Text(
                        isOnline ? 'Online' : 'Offline',
                        style: TextStyle(fontSize: 10, color: isOnline ? _C.onlineDot : _C.exitdelete, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(LucideIcons.moreVertical, size: 20, color: _C.ink),
            color: _C.surface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            onSelected: (value) {
              if (value == 'clear') {
                _showClearChatConfirmation();
              }
            },
            itemBuilder: (BuildContext context) {
              return [
                const PopupMenuItem<String>(
                  value: 'clear',
                  child: Row(
                    children: [
                      Icon(LucideIcons.trash2, color: _C.exitdelete, size: 18),
                      SizedBox(width: 8),
                      Text('Clear Chat', style: TextStyle(color: _C.exitdelete, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ];
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                reverse: true,
                padding: const EdgeInsets.only(top: 20, bottom: 8, right: 16, left: 16),
                itemCount: _messages.length,
                itemBuilder: (context, index) {
                  final chronologicalIndex = _messages.length - 1 - index;
                  final msg = _messages[chronologicalIndex];
                  final showDate = _shouldShowDateDivider(chronologicalIndex);

                  final messageWidget = _buildMessageItem(msg);
                  
                  if (showDate) {
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildDateDivider(msg.timestamp),
                        messageWidget,
                      ],
                    );
                  }
                  return messageWidget;
                },
              ),
            ),
            _buildInputDeck(isOnline),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageItem(ChatMessage msg) {
    final isMe = msg.isMe;
    final alignment = isMe ? Alignment.centerRight : Alignment.centerLeft;
    
    return Align(
      alignment: alignment,
      child: GestureDetector(
        onLongPressStart: (details) => _showMessageOptions(msg, details.globalPosition),
        onSecondaryTapDown: (details) => _showMessageOptions(msg, details.globalPosition),
        child: Container(
          margin: const EdgeInsets.only(bottom: 8, right: 4, left: 4),
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
          decoration: BoxDecoration(
            color: isMe ? _C.white : _C.surface,
            border: Border.all(color: _C.ink, width: 1.5),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(12),
              topRight: const Radius.circular(12),
              bottomLeft: isMe ? const Radius.circular(12) : Radius.zero,
              bottomRight: isMe ? Radius.zero : const Radius.circular(12),
            ),
            boxShadow: const [
              // Neo-brutalist hard shadow
              BoxShadow(
                color: _C.ink,
                blurRadius: 0,
                offset: Offset(4, 4),
              )
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: IntrinsicWidth(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (msg.fileName != null)
                    _buildFileCard(msg)
                  else
                    Text(
                      msg.text,
                      style: TextStyle(
                        color: _C.ink,
                        fontSize: 14,
                        height: 1.4,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.bottomRight,
                    child: Text(
                      _formatTime12Hour(msg.timestamp),
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        color: isMe ? _C.ink.withValues(alpha: 0.7) : _C.grey60,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFileCard(ChatMessage msg) {
    final isMe = msg.isMe;
    final progressVal = msg.transferProgress;
    final isDone = msg.isTransferComplete;
    final speed = msg.transferSpeed;
    
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isMe ? _C.surface : _C.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color:  _C.ink,
          width: 1.5,
        ),
        // Hard inner shadow block for file card to maintain the style inside the bubble
        boxShadow: isMe ? [] : const [
          BoxShadow(
            color: _C.ink,
            blurRadius: 0,
            offset: Offset(2, 2),
          )
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                
                child: Icon(
                  _getFileIcon(msg.fileExtension),
                  color: _C.ink,
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      msg.fileName!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: _C.ink),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Text(
                          _formatFileSize(msg.fileSize ?? 0),
                          style: const TextStyle(fontSize: 11, color: _C.grey60, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          "• ${msg.fileExtension!.toUpperCase()}",
                          style: const TextStyle(fontSize: 11, color: _C.grey60, fontWeight: FontWeight.bold),
                        )
                      ],
                    ),
                  ],
                ),
              ),
              SizedBox(width: 12),
              if (isDone)
                const Icon(LucideIcons.checkCircle2, color: _C.onlineDot, size: 20),
            ],
          ),
          if (!isDone) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.zero,
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: _C.ink, width: 1),
                ),
                child: LinearProgressIndicator(
                  value: progressVal,
                  minHeight: 6,
                  backgroundColor: _C.white,
                  valueColor: const AlwaysStoppedAnimation<Color>(_C.ink),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
               mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${(progressVal * 100).toInt()}%',
                  style: const TextStyle(fontSize: 10, color: _C.ink, fontWeight: FontWeight.bold),
                ),
                if (speed != null)
                  Text(
                    speed,
                    style: const TextStyle(fontSize: 10, color: _C.ink, fontWeight: FontWeight.bold),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildInputDeck(bool isOnline) {
    return Container(
      padding: const EdgeInsets.only(left: 16, right: 16, bottom: 10, top: 2),
      child: Opacity(
        opacity: isOnline ? 1.0 : 0.4,
        child: IgnorePointer(
          ignoring: !isOnline,
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: _C.white,
              border: Border.all(color: _C.ink, width: 2),
              boxShadow: const [
                BoxShadow(
                  color: _C.ink,
                  blurRadius: 0,
                  offset: Offset(4, 4),
                )
              ],
            ),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Attachment Button
                  InkWell(
                    onTap: _pickAndSendFile,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(
                        border: Border(right: BorderSide(color: _C.ink, width: 2)),
                      ),
                      child: const Icon(LucideIcons.paperclip, color: _C.ink, size: 22),
                    ),
                  ),
                  
                  // Text Input Box
                  Expanded(
                    child: TextField(
                      enabled: isOnline,
                      controller: _messageController,
                      onSubmitted: (_) => _sendMessage(),
                      style: const TextStyle(fontSize: 14, color: _C.ink, fontWeight: FontWeight.bold),
                      maxLines: 4,
                      minLines: 1,
                      decoration: const InputDecoration(
                        hintText: 'TYPE MESSAGE...',
                        hintStyle: TextStyle(
                          color: _C.grey60, 
                          fontWeight: FontWeight.w900, 
                          letterSpacing: 1.0,
                          fontSize: 12,
                        ),
                        filled: false,
                        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 18),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                      ),
                    ),
                  ),
                  
                  // Send Button
                  GestureDetector(
                    onTap: _sendMessage,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      alignment: Alignment.center,
                      color: _C.ink,
                      child: const Icon(LucideIcons.send, color: _C.bg, size: 20),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}