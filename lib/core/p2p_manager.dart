import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:media_scanner/media_scanner.dart';
import 'package:omnidrop/models/chat_message.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:device_marketing_names/device_marketing_names.dart';

class P2PMessageEvent {
  final String peerUsername;
  final ChatMessage? message;
  final bool isProgressUpdate;
  final bool isConnectionStatusUpdate;
  final bool isProfileUpdate;
  final String? toastMessage;

  P2PMessageEvent({
    required this.peerUsername,
    this.message,
    this.isProgressUpdate = false,
    this.isConnectionStatusUpdate = false,
    this.isProfileUpdate = false,
    this.toastMessage,
  });
}

class P2PManager {
  static final P2PManager _instance = P2PManager._internal();
  factory P2PManager() => _instance;
  P2PManager._internal();

  String? _myUsername;
  String? _myDisplayName;
  String? _myDeviceModel;
  RawDatagramSocket? _discoverySocket;
  ServerSocket? _chatServer;
  Timer? _discoveryTimer;
  bool _isInitialized = false;
  
  // Supabase signaling channel for 100% reliable discovery
  dynamic _presenceChannel;

  // Pre-cached paired devices for synchronous security checks.
  // Loaded from SharedPreferences during init() so we never have to
  // do an async read AFTER a socket connection is already accepted.
  Set<String> _cachedPairedDevices = {};

  // Pre-resolved writable temporary directory path (set during init).
  // Directory.systemTemp is unreliable in background service isolates on Android.
  String? _tempDirPath;

  final Map<String, InternetAddress> peerIpAddresses = {};
  final Map<String, DateTime> peerLastSeen = {};
  final StreamController<P2PMessageEvent> _eventController = StreamController<P2PMessageEvent>.broadcast();

  Stream<P2PMessageEvent> get eventStream => _eventController.stream;

  bool isPeerOnline(String username) {
    final lastSeen = peerLastSeen[username];
    if (lastSeen == null) return false;
    // Consider peer offline if no heartbeat received for 6 seconds (broadcasting every 2s)
    return DateTime.now().difference(lastSeen).inSeconds < 6;
  }

  bool get isInitialized => _isInitialized;

  Future<void> init({bool isBackgroundIsolate = false}) async {
    // Guard: if already initialized, do nothing.
    // Each Dart isolate (main app vs background service) has its own singleton instance,
    // so the background service always starts with _isInitialized = false.
    // Within the main app, both main.dart and HomeScreen call init() — the guard
    // ensures the second call is a safe no-op instead of tearing down live sockets.
    if (_isInitialized) return;

    final prefs = await SharedPreferences.getInstance();
    _myUsername = prefs.getString('username');
    _myDisplayName = prefs.getString('display_name') ?? _myUsername;
    _myDeviceModel = prefs.getString('device_model');
    // Force regenerate if it's not a JSON string (migrating from old plain string cache)
    if (_myDeviceModel == null || !_myDeviceModel!.startsWith('{')) {
      _myDeviceModel = await _getHardwareDeviceModel();
      await prefs.setString('device_model', _myDeviceModel!);
    }

    if (_myUsername == null) {
      debugPrint('[P2PManager] No username set, skipping initialization.');
      return;
    }

    // Pre-load paired devices into memory for synchronous security checks.
    // This prevents the race condition where an async SharedPreferences read
    // would call socket.close() AFTER file data has already started flowing.
    final pairedList = prefs.getStringList('local_paired_devices') ?? [];
    _cachedPairedDevices = Set<String>.from(pairedList);
    debugPrint('[P2PManager] Cached paired devices: $_cachedPairedDevices');

    // Pre-resolve a writable temp directory. Directory.systemTemp on Android
    // background service isolates often resolves to /tmp which does not exist.
    // path_provider.getTemporaryDirectory() returns the app cache dir (/data/...).
    try {
      final tmpDir = await getTemporaryDirectory();
      _tempDirPath = tmpDir.path;
    } catch (_) {
      _tempDirPath = Directory.systemTemp.path;
    }
    debugPrint('[P2PManager] Temp dir: $_tempDirPath');

    _isInitialized = true;
    _startDiscoveryAndChatServer();

    // Listen for cross-isolate events from the background service.
    // This allows the main UI isolate to receive progress updates and message
    // completions from the background service isolate in real-time.
    // WARNING: FlutterBackgroundService() throws if instantiated in the background isolate!
    if (!isBackgroundIsolate && (Platform.isAndroid || Platform.isIOS)) {
      try {
        FlutterBackgroundService().on('p2p_event').listen((event) {
          if (event == null) return;
          final peerUsername = event['peerUsername'] as String?;
          if (peerUsername == null) return;
          
          ChatMessage? msg;
          if (event['message'] != null) {
            msg = ChatMessage.fromJson(Map<String, dynamic>.from(event['message']));
          }
          
          _eventController.add(P2PMessageEvent(
            peerUsername: peerUsername,
            message: msg,
            isProgressUpdate: event['isProgressUpdate'] == true,
            isConnectionStatusUpdate: event['isConnectionStatusUpdate'] == true,
            isProfileUpdate: event['isProfileUpdate'] == true,
            toastMessage: event['toastMessage'] as String?,
          ));
        });
      } catch (e) {
        debugPrint('[P2PManager] Error setting up background service listener: $e');
      }
    }

    debugPrint('[P2PManager] Initialized for $_myUsername');
  }

  /// Internal hard reset — tears down all sockets/timers WITHOUT setting _isInitialized
  /// (the caller manages that flag). Safe to call from any isolate.
  void _forceReset() {
    _discoveryTimer?.cancel();
    _discoveryTimer = null;

    try { _discoverySocket?.close(); } catch (_) {}
    _discoverySocket = null;

    try { _chatServer?.close(); } catch (_) {}
    _chatServer = null;

    try {
      if (_presenceChannel != null) {
        _presenceChannel.unsubscribe();
      }
    } catch (_) {}
    _presenceChannel = null;

    _isInitialized = false;
    _cachedPairedDevices = {};
    _tempDirPath = null;
    _myDeviceModel = null;
    peerIpAddresses.clear();
    peerLastSeen.clear();
    debugPrint('[P2PManager] Force-reset complete');
  }

  Future<String> _getHardwareDeviceModel() async {
    try {
      final deviceInfo = DeviceInfoPlugin();
      final marketingNames = DeviceMarketingNames();
      Map<String, dynamic> details = {};
      
      if (Platform.isAndroid) {
        final info = await deviceInfo.androidInfo;
        final brand = info.brand.isNotEmpty ? '${info.brand[0].toUpperCase()}${info.brand.substring(1)}' : info.brand;
        final singleName = await marketingNames.getSingleName();
        final finalName = (singleName.isNotEmpty && singleName != info.model) 
            ? '$brand $singleName' 
            : '$brand ${info.model}';

        details = {
          'name': finalName,
          'os': 'Android ${info.version.release}',
          'sdk': info.version.sdkInt.toString(),
          'manufacturer': info.manufacturer,
          'product': info.product,
          'hardware': info.hardware,
          'device': info.device,
          'board': info.board,
          'type': 'Mobile',
        };
      } else if (Platform.isWindows) {
        final info = await deviceInfo.windowsInfo;
        details = {
          'name': info.computerName,
          'os': info.productName,
          'cores': info.numberOfCores.toString(),
          'ram': '${info.systemMemoryInMegabytes} MB',
          'build': info.buildNumber.toString(),
          'type': 'Desktop',
        };
      } else if (Platform.isIOS) {
        final info = await deviceInfo.iosInfo;
        details = {
          'name': info.name,
          'model': info.model,
          'os': '${info.systemName} ${info.systemVersion}',
          'machine': info.utsname.machine,
          'type': 'Mobile',
        };
      } else if (Platform.isMacOS) {
        final info = await deviceInfo.macOsInfo;
        details = {
          'name': info.computerName,
          'model': info.model,
          'os': info.osRelease,
          'arch': info.arch,
          'type': 'Desktop',
        };
      } else if (Platform.isLinux) {
        final info = await deviceInfo.linuxInfo;
        details = {
          'name': info.prettyName,
          'os': info.name,
          'version': info.version,
          'machine': info.machineId,
          'type': 'Desktop',
        };
      }
      return jsonEncode(details);
    } catch (e) {
      debugPrint('[P2PManager] Error getting device info: $e');
    }
    return jsonEncode({'name': 'Unknown Device', 'type': 'Unknown'});
  }

  void stop() {
    _forceReset();
    debugPrint('[P2PManager] Stopped');
  }

  void requestReverseConnection(String targetUsername, int port) async {
    if (_presenceChannel == null || _myUsername == null) return;
    
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      String? localIp;
      for (var interface in interfaces) {
        if (interface.name.toLowerCase().contains('vethernet') || interface.name.toLowerCase().contains('wsl') || interface.name.toLowerCase().contains('virtual')) continue;
        for (var addr in interface.addresses) {
          if (!addr.isLoopback && addr.address.contains('.')) {
            localIp ??= addr.address;
            if (addr.address.startsWith('192.168.')) {
              localIp = addr.address;
              break;
            }
          }
        }
        if (localIp != null && localIp.startsWith('192.168.')) break;
      }
      
      if (localIp != null) {
        debugPrint('[P2PManager] Requesting reverse connection from $targetUsername to $localIp:$port');
        _presenceChannel!.sendBroadcastMessage(
          event: 'reverse_connect',
          payload: {
            'target': targetUsername,
            'sender': _myUsername,
            'ip': localIp,
            'port': port,
          },
        );
      }
    } catch (e) {
      debugPrint('[P2PManager] Error sending reverse connect request: $e');
    }
  }

  void sendUnpairSignal(String targetUsername) {
    if (_presenceChannel == null || _myUsername == null) return;
    try {
      debugPrint('[P2PManager] Sending unpair signal to $targetUsername');
      _presenceChannel!.sendBroadcastMessage(
        event: 'unpair',
        payload: {
          'target': targetUsername,
          'sender': _myUsername,
        },
      );
    } catch (e) {
      debugPrint('[P2PManager] Error sending unpair signal: $e');
    }
  }

  void updateDisplayName(String newName) {
    _myDisplayName = newName;
  }

  void broadcastProfileUpdate(String newName, String? newAvatar) async {
    _myDisplayName = newName;
    if (_myUsername == null) return;
    
    final payload = jsonEncode({
      'type': 'profile_update',
      'sender': _myUsername,
      'displayName': newName,
      'avatar': newAvatar,
    });
    
    // Push the update instantly to all known online paired devices via TCP
    for (final peer in _cachedPairedDevices) {
      if (isPeerOnline(peer)) {
        final ip = peerIpAddresses[peer];
        if (ip != null) {
          try {
            final socket = await Socket.connect(ip, 40902, timeout: const Duration(seconds: 1));
            socket.setOption(SocketOption.tcpNoDelay, true);
            socket.write('$payload\n');
            await socket.flush();
            socket.close();
          } catch (e) {
            debugPrint('[P2PManager] Failed to push profile update to $peer: $e');
          }
        }
      }
    }
  }

  void _startDiscoveryAndChatServer() async {
    try {
      // 0. Connect to Supabase Realtime for reliable IP signaling (Fallback/Instant connect)
      try {
        final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
        String? localIp;
        
        // Priority 1: 192.168.x.x on a physical interface
        // Priority 2: 10.x.x.x or 172.x.x.x on a physical interface
        // Priority 3: Any non-loopback IPv4
        for (var interface in interfaces) {
          final name = interface.name.toLowerCase();
          // Skip known virtual/hypervisor adapters
          if (name.contains('vethernet') || name.contains('wsl') || name.contains('virtual') || name.contains('vmware') || name.contains('tailscale') || name.contains('vpn')) {
            continue;
          }
          for (var addr in interface.addresses) {
            if (!addr.isLoopback && addr.address.contains('.')) {
              localIp ??= addr.address;
              if (addr.address.startsWith('192.168.')) {
                localIp = addr.address; // Best match
                break;
              }
            }
          }
          if (localIp != null && localIp.startsWith('192.168.')) break;
        }

        if (localIp != null && _myUsername != null) {
          _presenceChannel = Supabase.instance.client.channel('presence:global');
          
          _presenceChannel!.onBroadcast(
            event: 'ip_exchange',
            callback: (payload) {
              if (payload['user'] != null && payload['user'] != _myUsername && payload['ip'] != null) {
                final String peerUser = payload['user'];
                final bool isNew = peerIpAddresses[peerUser] == null;
                peerIpAddresses[peerUser] = InternetAddress(payload['ip']);
                peerLastSeen[peerUser] = DateTime.now();
                
                if (isNew) {
                  _eventController.add(P2PMessageEvent(
                    peerUsername: peerUser,
                    isConnectionStatusUpdate: true,
                  ));
                }
              }
            },
          ).onBroadcast(
            event: 'reverse_connect',
            callback: (payload) async {
              if (payload['target'] == _myUsername && payload['sender'] != null && payload['port'] != null && payload['ip'] != null) {
                final String senderUser = payload['sender'];
                final String senderIp = payload['ip'];
                final int port = payload['port'];
                
                try {
                  debugPrint('[P2PManager] Accepting reverse connection from $senderUser at $senderIp:$port');
                  final reverseSocket = await Socket.connect(
                    InternetAddress(senderIp),
                    port,
                    timeout: const Duration(seconds: 5),
                  );
                  reverseSocket.setOption(SocketOption.tcpNoDelay, true);
                  // Treat this outgoing socket exactly like an incoming ServerSocket connection!
                  _handleIncomingChatData(reverseSocket);
                } catch (e) {
                  debugPrint('[P2PManager] Failed to connect back to reverse socket: $e');
                }
              }
            },
          ).onBroadcast(
            event: 'unpair',
            callback: (payload) async {
              if (payload['target'] == _myUsername && payload['sender'] != null) {
                final String senderUser = payload['sender'];
                debugPrint('[P2PManager] Received unpair signal from $senderUser');
                
                final prefs = await SharedPreferences.getInstance();
                final list = prefs.getStringList('local_paired_devices') ?? [];
                
                if (list.contains(senderUser)) {
                  list.remove(senderUser);
                  await prefs.setStringList('local_paired_devices', list);
                  
                  final registryStr = prefs.getString('paired_devices_registry') ?? '{}';
                  final registry = jsonDecode(registryStr) as Map<String, dynamic>;
                  registry.remove(senderUser);
                  await prefs.setString('paired_devices_registry', jsonEncode(registry));
                  
                  _cachedPairedDevices.remove(senderUser);
                  
                  _eventController.add(P2PMessageEvent(
                    peerUsername: senderUser,
                    isConnectionStatusUpdate: true,
                    toastMessage: '"$senderUser" has unpaired from your device.',
                  ));
                }
              }
            },
          ).subscribe();

          // Periodically broadcast our IP via Supabase as long as we are alive
          Timer.periodic(const Duration(seconds: 3), (timer) {
            if (_presenceChannel == null || _myUsername == null) {
              timer.cancel();
              return;
            }
            try {
              _presenceChannel!.sendBroadcastMessage(
                event: 'ip_exchange',
                payload: {'user': _myUsername, 'ip': localIp},
              );
            } catch (_) {}
          });
        }
      } catch (e) {
        debugPrint('[P2PManager] Supabase signaling init failed: $e');
      }

      // 1. Bind UDP presence socket to broadcast we are online
      _discoverySocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        40900,
        reuseAddress: true,
      );
      _discoverySocket!.broadcastEnabled = true;

      _discoverySocket!.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final datagram = _discoverySocket!.receive();
          if (datagram != null) {
            try {
              final msg = utf8.decode(datagram.data).trim();
              if (msg.startsWith('OMNIDROP_ALIVE:')) {
                final parts = msg.split(':');
                if (parts.length >= 2) {
                  final discoveredUser = parts[1];
                  String discoveredName = discoveredUser;
                  String discoveredModel = 'Unknown Device';
                  
                  if (parts.length >= 3) {
                    try {
                      discoveredName = utf8.decode(base64Decode(parts[2]));
                    } catch (_) {}
                  }
                  if (parts.length >= 4) {
                    try {
                      discoveredModel = utf8.decode(base64Decode(parts[3]));
                    } catch (_) {}
                  }
                  
                  if (discoveredUser != _myUsername) {
                    final isNew = peerIpAddresses[discoveredUser] == null;
                    peerIpAddresses[discoveredUser] = datagram.address;
                    peerLastSeen[discoveredUser] = DateTime.now();
                    
                    // Update shared preferences with discovered name silently
                    if (isNew || true) {
                      SharedPreferences.getInstance().then((p) async {
                        await p.reload();
                        bool changed = false;
                        
                        final namesStr = p.getString('paired_devices_names') ?? '{}';
                        final namesMap = jsonDecode(namesStr) as Map<String, dynamic>;
                        if (namesMap[discoveredUser] != discoveredName) {
                          namesMap[discoveredUser] = discoveredName;
                          await p.setString('paired_devices_names', jsonEncode(namesMap));
                          changed = true;
                        }
                        
                        final modelsStr = p.getString('paired_devices_models') ?? '{}';
                        final modelsMap = jsonDecode(modelsStr) as Map<String, dynamic>;
                        if (modelsMap[discoveredUser] != discoveredModel) {
                          modelsMap[discoveredUser] = discoveredModel;
                          await p.setString('paired_devices_models', jsonEncode(modelsMap));
                          changed = true;
                        }

                        if (changed) {
                          _eventController.add(P2PMessageEvent(
                            peerUsername: discoveredUser,
                            isProfileUpdate: true,
                          ));
                        }
                      });
                    }

                    if (isNew) {
                      _eventController.add(P2PMessageEvent(
                        peerUsername: discoveredUser,
                        isConnectionStatusUpdate: true,
                      ));
                    }
                  }
                }
              }
            } catch (e) {
              debugPrint('[P2PManager] Error parsing UDP alive datagram: $e');
            }
          }
        }
      },
      onError: (error) {
        debugPrint('[P2PManager] UDP discovery socket error: $error');
      },
      onDone: () {
        debugPrint('[P2PManager] UDP discovery socket closed.');
      },
      cancelOnError: false,
      );

      // Periodically broadcast presence
      _discoveryTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
        if (_discoverySocket == null || _myUsername == null) return;

        // Reload SharedPreferences dynamically to fetch any display name changes from the other isolate.
        String currentName = _myUsername!;
        String currentModel = _myDeviceModel ?? 'Unknown Device';
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.reload();
          currentName = prefs.getString('display_name') ?? _myUsername!;
          currentModel = prefs.getString('device_model') ?? currentModel;
        } catch (_) {
          // Fall back to memory copy if SharedPreferences throws or is uninitialized
          currentName = _myDisplayName ?? _myUsername!;
        }

        final nameB64 = base64Encode(utf8.encode(currentName));
        final modelB64 = base64Encode(utf8.encode(currentModel));
        final data = utf8.encode('OMNIDROP_ALIVE:$_myUsername:$nameB64:$modelB64');
        
        // Broadcast to 255.255.255.255
        try {
          _discoverySocket!.send(data, InternetAddress('255.255.255.255'), 40900);
        } catch (e) {
          debugPrint('[P2PManager] Error sending generic UDP broadcast: $e');
        }

        // Broadcast to specific subnets to bypass AP isolation / strict Android rules
        try {
          final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
          for (var interface in interfaces) {
            for (var addr in interface.addresses) {
              if (!addr.isLoopback && addr.address.contains('.')) {
                final parts = addr.address.split('.');
                if (parts.length == 4) {
                  final subnetBroadcast = '${parts[0]}.${parts[1]}.${parts[2]}.255';
                  try {
                    _discoverySocket!.send(data, InternetAddress(subnetBroadcast), 40900);
                  } catch (_) {}
                }
              }
            }
          }
        } catch (e) {
          debugPrint('[P2PManager] Error sending subnet UDP broadcasts: $e');
        }
      });

      // 2. Start TCP Chat Server
      // shared: true sets SO_REUSEPORT — allows rebinding the same port immediately
      // after the service is killed and restarted (e.g. Quick Tile toggle OFF → ON).
      // Without this, the bind() throws 'Address already in use' if the old socket
      // is still in TIME_WAIT state, leaving _chatServer null and silently broken.
      _chatServer = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        40902,
        shared: true,
      );
      _chatServer!.listen((Socket clientSocket) {
        clientSocket.setOption(SocketOption.tcpNoDelay, true);
        _handleIncomingChatData(clientSocket);
      });
    } catch (e) {
      debugPrint('[P2PManager] Error starting P2P network: $e');
    }
  }

  void _handleIncomingChatData(Socket socket) {
    final List<int> buffer = [];
    bool parsedHeader = false;
    Map<String, dynamic>? metadata;
    IOSink? fileSink;
    String? tempFilePath;
    int receivedBytes = 0;
    int totalFileSize = 0;
    ChatMessage? fileMsg;
    Timer? progressTimer;
    BytesBuilder? diskBuffer;
    const int diskWriteThreshold = 1024 * 1024 * 2; // 2 MB Batch Size
    String? sender;

    socket.listen(
      (data) {
        if (!parsedHeader) {
          buffer.addAll(data);
          final newlineIndex = buffer.indexOf(10); // '\n'
          if (newlineIndex != -1) {
            try {
              final headerBytes = buffer.sublist(0, newlineIndex);
              final headerStr = utf8.decode(headerBytes);
              metadata = jsonDecode(headerStr);
              parsedHeader = true;

              final remaining = buffer.sublist(newlineIndex + 1);
              buffer.clear();

              sender = metadata!['sender'] as String;
              peerIpAddresses[sender!] = socket.remoteAddress;

              final displayName = metadata!['displayName'] as String?;
              final avatar = metadata!['avatar'] as String?;
              
              if (displayName != null || avatar != null) {
                // Update SharedPreferences seamlessly in the background
                SharedPreferences.getInstance().then((p) async {
                  await p.reload();
                  bool changed = false;
                  if (displayName != null) {
                    final namesStr = p.getString('paired_devices_names') ?? '{}';
                    final namesMap = jsonDecode(namesStr) as Map<String, dynamic>;
                    if (namesMap[sender] != displayName) {
                      namesMap[sender!] = displayName;
                      await p.setString('paired_devices_names', jsonEncode(namesMap));
                      changed = true;
                    }
                  }
                  if (avatar != null) {
                    final regStr = p.getString('paired_devices_registry') ?? '{}';
                    final regMap = jsonDecode(regStr) as Map<String, dynamic>;
                    if (regMap[sender] != avatar) {
                      regMap[sender!] = avatar;
                      await p.setString('paired_devices_registry', jsonEncode(regMap));
                      changed = true;
                    }
                  }
                  if (changed) {
                    _eventController.add(P2PMessageEvent(
                      peerUsername: sender!,
                      isProfileUpdate: true,
                    ));
                  }
                });
              }

              final type = metadata!['type'] as String?;
              if (type == 'ping') {
                socket.close();
                return;
              }
              if (type == 'profile_update') {
                socket.close();
                return;
              }

              // === SYNCHRONOUS SECURITY CHECK ===
              // Use the paired-devices list that was pre-loaded into memory during
              // init(). This avoids the race condition where an async
              // SharedPreferences read could call socket.close() AFTER megabytes
              // of file data have already flowed in, causing the sender to hang.
              if (!_cachedPairedDevices.contains(sender)) {
                debugPrint('[P2PManager] Rejecting unpaired sender: $sender | known: $_cachedPairedDevices');
                socket.close();
                return;
              }

              final text = metadata!['text'] as String? ?? '';
              final fileName = metadata!['fileName'] as String?;
              final fileSize = metadata!['fileSize'] as int?;
              final fileExtension = metadata!['fileExtension'] as String?;

              if (fileName != null) {
                totalFileSize = fileSize ?? 0;

                fileMsg = ChatMessage(
                  text: text,
                  isMe: false,
                  timestamp: DateTime.now(),
                  fileName: fileName,
                  fileSize: totalFileSize,
                  fileExtension: fileExtension,
                  transferProgress: 0.0,
                  isTransferComplete: false,
                  transferSpeed: '0.0 MB/s',
                );

                // Use the pre-resolved app temp directory (set in init()).
                // Directory.systemTemp on Android background service often resolves
                // to /tmp which does not exist and causes openWrite() to fail.
                final baseTempPath = _tempDirPath ?? Directory.systemTemp.path;
                tempFilePath = '$baseTempPath/$fileName';
                fileSink = File(tempFilePath!).openWrite();
                diskBuffer = BytesBuilder(copy: false);

                if (remaining.isNotEmpty) {
                  diskBuffer!.add(remaining);
                  receivedBytes += remaining.length;
                }

                progressTimer = Timer.periodic(
                  const Duration(milliseconds: 100),
                  (_) {
                    if (totalFileSize <= 0) return;
                    final progress = (receivedBytes / totalFileSize).clamp(0.0, 1.0);
                    fileMsg!.transferProgress = progress;
                    fileMsg!.transferSpeed =
                        '${(receivedBytes / (1024 * 1024)).toStringAsFixed(1)} MB / ${(totalFileSize / (1024 * 1024)).toStringAsFixed(1)} MB';
                    _eventController.add(P2PMessageEvent(
                      peerUsername: sender!,
                      message: fileMsg!,
                      isProgressUpdate: true,
                    ));
                  },
                );

                // Async: save initial file message to history and notify UI.
                // Security is already handled above (synchronous), so this
                // is purely for persistence and event emission.
                () async {
                  try {
                    await _saveMessageToHistory(sender!, fileMsg!);
                    _eventController.add(P2PMessageEvent(peerUsername: sender!, message: fileMsg!));
                  } catch (e) {
                    debugPrint('[P2PManager] Error saving initial file message: $e');
                  }
                }();
                
              } else {
                // Text message
                final textMsg = ChatMessage(
                  text: text,
                  isMe: false,
                  timestamp: DateTime.now(),
                );
                
                () async {
                  try {
                    await _saveMessageToHistory(sender!, textMsg);
                    _eventController.add(P2PMessageEvent(peerUsername: sender!, message: textMsg));
                  } catch (e) {
                    debugPrint('[P2PManager] Error saving text message: $e');
                  }
                }();
              }
            } catch (e) {
              debugPrint('[P2PManager] Error parsing incoming TCP header: $e');
              socket.close();
            }
          }
        } else {
          if (fileSink != null && diskBuffer != null) {
            diskBuffer!.add(data);
            receivedBytes += data.length;
            
            if (diskBuffer!.length >= diskWriteThreshold) {
              fileSink!.add(diskBuffer!.takeBytes());
            }
          }
        }
      },
      onError: (e) {
        debugPrint('[P2PManager] Socket incoming read error: $e');
      },
      onDone: () async {
        progressTimer?.cancel();
        socket.close();

        if (fileSink != null) {
          if (diskBuffer != null && diskBuffer!.isNotEmpty) {
            fileSink!.add(diskBuffer!.takeBytes());
          }
          await fileSink!.flush();
          await fileSink!.close();
        }

        if (metadata != null &&
            metadata!['fileName'] != null &&
            fileMsg != null &&
            tempFilePath != null &&
            sender != null) {
          final fileName = metadata!['fileName'] as String;
          try {
            fileMsg!.transferProgress = 1.0;
            fileMsg!.isTransferComplete = true;
            fileMsg!.transferSpeed = null;

            final saveResult = await _saveReceivedFile(fileName, tempFilePath!);
            
            await _updateMessageInHistory(sender!, fileMsg!);
            
            // Notify UI to show toast instead of pushing a bubble to history
            _eventController.add(P2PMessageEvent(
              peerUsername: sender!, 
              message: fileMsg!,
              toastMessage: 'File saved: $fileName',
            ));
          } catch (e) {
            debugPrint('[P2PManager] Error saving received file: $e');
            _eventController.add(P2PMessageEvent(
              peerUsername: sender!, 
              message: fileMsg!,
              toastMessage: 'Failed to save received file $fileName',
            ));
          }
        }
      },
      cancelOnError: true,
    );
  }

  Future<void> _saveMessageToHistory(String peerUsername, ChatMessage msg) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = 'chat_history_$peerUsername';
      final rawList = prefs.getStringList(key) ?? [];
      rawList.add(jsonEncode(msg.toJson()));
      await prefs.setStringList(key, rawList);
    } catch (e) {
      debugPrint('[P2PManager] Error saving message to history: $e');
    }
  }

  Future<void> _updateMessageInHistory(String peerUsername, ChatMessage msg) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = 'chat_history_$peerUsername';
      final rawList = prefs.getStringList(key) ?? [];
      
      // Try to find matching message by file name or timestamp
      int index = -1;
      for (int i = rawList.length - 1; i >= 0; i--) {
        final existingMsg = ChatMessage.fromJson(jsonDecode(rawList[i]));
        if (existingMsg.fileName == msg.fileName && 
            existingMsg.timestamp.difference(msg.timestamp).inSeconds.abs() < 10) {
          index = i;
          break;
        }
      }
      
      if (index != -1) {
        rawList[index] = jsonEncode(msg.toJson());
        await prefs.setStringList(key, rawList);
      }
    } catch (e) {
      debugPrint('[P2PManager] Error updating message in history: $e');
    }
  }

  Future<String> _saveReceivedFile(String fileName, String tempFilePath) async {
    try {
      final tempFile = File(tempFilePath);
      final extension = fileName.split('.').last.toLowerCase();
      final isImage = ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'].contains(extension);
      final isVideo = ['mp4', 'mov', 'avi', 'mkv', '3gp'].contains(extension);

      if ((isImage || isVideo) && (Platform.isAndroid || Platform.isIOS)) {
        try {
          bool hasAccess = false;
          try {
            hasAccess = await Gal.hasAccess();
            if (!hasAccess) {
              await Gal.requestAccess();
              hasAccess = await Gal.hasAccess();
            }
          } catch (e) {
            debugPrint('[P2PManager] Gal access check failed: $e');
          }

          if (hasAccess) {
            if (isImage) {
              await Gal.putImage(tempFile.path, album: 'OmniDrop');
            } else {
              await Gal.putVideo(tempFile.path, album: 'OmniDrop');
            }
            try {
              await tempFile.delete();
            } catch (_) {}
            return 'Saved to Photo Gallery (OmniDrop album)';
          }
        } catch (e) {
          debugPrint('[P2PManager] Gallery save failed, trying fallback: $e');
        }
      }

      String? targetDirPath;
      if (Platform.isWindows) {
        final downloadsDir = await getDownloadsDirectory();
        if (downloadsDir != null) {
          targetDirPath = '${downloadsDir.path}/OmniDrop';
        }
      } else if (Platform.isAndroid) {
        // Attempt to save directly to the public Downloads folder so files show up in Google Files app automatically.
        // Android 10+ allows apps to create files in public directories (like Download) without special permissions.
        final publicDownloadsDir = Directory('/storage/emulated/0/Download/OmniDrop');
        try {
          if (!await publicDownloadsDir.exists()) {
            await publicDownloadsDir.create(recursive: true);
          }
          targetDirPath = publicDownloadsDir.path;
        } catch (e) {
          debugPrint('[P2PManager] Failed to create public downloads folder, falling back to scoped storage: $e');
          final extDir = await getExternalStorageDirectory();
          if (extDir != null) {
            targetDirPath = '${extDir.path}/OmniDrop';
          }
        }
      }

      if (targetDirPath == null) {
        final docDir = await getApplicationDocumentsDirectory();
        targetDirPath = '${docDir.path}/OmniDrop';
      }

      final targetDir = Directory(targetDirPath);
      if (!await targetDir.exists()) {
        await targetDir.create(recursive: true);
      }

      String uniqueFileName = fileName;
      File finalFile = File('${targetDir.path}/$uniqueFileName');
      int counter = 1;

      // Extract base name and extension to correctly append the number
      String baseName = fileName;
      String ext = '';
      final lastDotIndex = fileName.lastIndexOf('.');
      if (lastDotIndex != -1) {
        baseName = fileName.substring(0, lastDotIndex);
        ext = fileName.substring(lastDotIndex);
      }

      // Loop until we find a filename that doesn't exist yet
      while (await finalFile.exists()) {
        uniqueFileName = '$baseName($counter)$ext';
        finalFile = File('${targetDir.path}/$uniqueFileName');
        counter++;
      }

      await tempFile.copy(finalFile.path);
      try {
        await tempFile.delete();
      } catch (_) {}
      
      // Trigger native Android MediaScannerConnection to index the file
      if (Platform.isAndroid) {
        try {
          final String? loadMediaResult = await MediaScanner.loadMedia(path: finalFile.path);
          debugPrint('[P2PManager] Triggered native media scan for ${finalFile.path}, result: $loadMediaResult');
        } catch (e) {
          debugPrint('[P2PManager] Error triggering native media scan: $e');
        }
      }
      
      // Show a friendly path for Android
      if (Platform.isAndroid) {
        if (targetDirPath.contains('Android/data')) {
          return 'Saved to OmniDrop folder. Open your file manager → Android → data → com.example.omnidrop → files → OmniDrop';
        } else {
          return 'Saved to Downloads folder (OmniDrop)';
        }
      }
      return 'Saved to ${finalFile.path}';

    } catch (e) {
      debugPrint('[P2PManager] Error saving file: $e');
      return 'Failed to save file: $e';
    }
  }
}
