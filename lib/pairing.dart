import 'package:google_fonts/google_fonts.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:omnidrop/core/sync_service.dart';
import 'chat.dart';

// =============================================================================
// PROTOCOL CONSTANTS
// =============================================================================

const _kProto = 'OMNIDROP:v2';
const _kBeacon = 'BEACON';
const _kPairReq = 'PAIR_REQ';
const _kPairAck = 'PAIR_ACK';

// =============================================================================
// DESIGN TOKENS  (mirrors homepage _C palette)
// =============================================================================

class _C {
  static const bg = Color(0xFFF5F0E8);
  static const surface = Color(0xFFEDE8DF);
  static const ink = Color(0xFF0A0A0A);
  static const border = Color(0xFFD4CEC4);
  static const borderDk = Color(0xFFB8B0A4);
  static const grey60 = Color(0xFF8A8278);
  static const grey30 = Color(0xFFB8B2A8);
  static const green = Color(0xFF2ECC71);
  static const red = Color(0xFFFF3232);
}

// =============================================================================
// DATA MODELS
// =============================================================================

class _HostInfo {
  final String username;
  final DateTime lastSeen;
  final InternetAddress? ipAddress;
  _HostInfo({required this.username, required this.lastSeen, this.ipAddress});
}

// =============================================================================
// MOCK BROKER
// =============================================================================

class _MockBroker {
  static String? pin;
  static String? hostUsername;
  static String? hostAvatar;
  static bool isLinked = false;

  static void register({
    required String p,
    required String username,
    String? avatar,
  }) {
    pin = p;
    hostUsername = username;
    hostAvatar = avatar;
    isLinked = false;
  }

  static void markLinked() => isLinked = true;
  static void reset() {
    pin = null;
    hostUsername = null;
    hostAvatar = null;
    isLinked = false;
  }
}

// =============================================================================
// STATE
// =============================================================================

enum _PairingState { idle, hosting, scanning, linking, success }

// =============================================================================
// SCREEN
// =============================================================================

class PairingScreen extends StatefulWidget {
  final String heroTag;
  const PairingScreen({super.key, this.heroTag = 'radio_icon_hero'});
  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen>
    with TickerProviderStateMixin {
  // ── Profile ─────────────────────────────────────────────────────────────────
  String _myUsername = 'User';
  String? _myAvatarBase64;

  final String _deviceId =
      '${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(999999)}';

  // ── State Machine ───────────────────────────────────────────────────────────
  _PairingState _state = _PairingState.idle;
  String _statusMessage = '';
  String _errorMessage = '';

  // ── Host side ───────────────────────────────────────────────────────────────
  String _myPin = '';

  // ── Client side ─────────────────────────────────────────────────────────────
  final Map<String, _HostInfo> _discoveredHosts = {};
  String _enteredPin = '';
  String? _detectedHostName;
  String? _pendingPin;

  // ── Sockets ─────────────────────────────────────────────────────────────────
  RealtimeChannel? _discoveryChannel;
  String _subnetId = 'global';

  // ── Timers ──────────────────────────────────────────────────────────────────
  Timer? _beaconTimer;
  Timer? _reqTimer;
  Timer? _soundTimer;
  Timer? _mockTimer;

  // ── Animations ──────────────────────────────────────────────────────────────
  late AnimationController _pulseCtrl;
  late AnimationController _scanCtrl;
  bool _isReverse = false;

  // ── PIN keyboard ─────────────────────────────────────────────────────────
  final TextEditingController _pinFieldCtrl = TextEditingController();
  final FocusNode _pinFocus = FocusNode();

  // =========================================================================
  // LIFECYCLE
  // =========================================================================

  @override
  void initState() {
    super.initState();
    _loadProfile();
    _pinFieldCtrl.addListener(_onPinFieldUpdated);

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );
    _scanCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    );
  }

  @override
  void dispose() {
    _shutdown();
    _pulseCtrl.dispose();
    _scanCtrl.dispose();
    _pinFieldCtrl.dispose();
    _pinFocus.dispose();
    _MockBroker.reset();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _myUsername = prefs.getString('username') ?? 'User';
      _myAvatarBase64 = prefs.getString('profile_image');
    });
  }

  // =========================================================================
  // SHUTDOWN / RESET
  // =========================================================================

  void _shutdown() {
    _beaconTimer?.cancel();
    _reqTimer?.cancel();
    _soundTimer?.cancel();
    _mockTimer?.cancel();
    _discoveryChannel?.unsubscribe();
    _discoveryChannel = null;
  }

  void _resetToIdle() {
    _shutdown();
    if (!mounted) return;
    _isReverse = true;
    setState(() {
      _state = _PairingState.idle;
      _myPin = '';
      _enteredPin = '';
      _detectedHostName = null;
      _pendingPin = null;
      _discoveredHosts.clear();
      _statusMessage = '';
      _errorMessage = '';
    });
    _pulseCtrl.stop();
    _scanCtrl.stop();
  }

  // =========================================================================
  // SUPABASE REALTIME DISCOVERY
  // =========================================================================

  Future<String> _getLocalSubnet() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      for (var ifc in interfaces) {
        for (var addr in ifc.addresses) {
          if (!addr.isLoopback && addr.address.startsWith('192.168.')) {
            final parts = addr.address.split('.');
            if (parts.length == 4) return '${parts[0]}.${parts[1]}.${parts[2]}';
          }
        }
      }
    } catch (_) {}
    return 'global';
  }

  Future<bool> _openSockets() async {
    try {
      _subnetId = await _getLocalSubnet();
      _discoveryChannel = Supabase.instance.client.channel(
        'discovery:$_subnetId',
      );
      _discoveryChannel!
          .onBroadcast(event: 'pairing_msg', callback: (p) => _onMessage(p))
          .subscribe();
      return true;
    } catch (e) {
      debugPrint('[Pairing] Supabase join failed: $e');
      return false;
    }
  }

  void _bcast(String msg, [InternetAddress? _]) {
    if (_discoveryChannel == null) return;
    _discoveryChannel!.sendBroadcastMessage(
      event: 'pairing_msg',
      payload: {'data': msg},
    );
  }

  // =========================================================================
  // MESSAGE DISPATCHER
  // =========================================================================

  void _onMessage(Map<String, dynamic> payload) {
    try {
      final msg = payload['data'] as String;
      if (!msg.startsWith(_kProto)) return;
      final parts = msg.split(':');
      if (parts.length < 4) return;
      switch (parts[2]) {
        case _kBeacon:
          _onBeacon(parts, null);
          break;
        case _kPairReq:
          _onPairReq(parts, null);
          break;
        case _kPairAck:
          _onPairAck(parts);
          break;
      }
    } catch (e) {
      debugPrint('[Pairing] Parse error: $e');
    }
  }

  // =========================================================================
  // HOST MODE
  // =========================================================================

  Future<void> _startHosting() async {
    _shutdown();
    final pin = _generatePin();
    _isReverse = false;
    setState(() {
      _state = _PairingState.hosting;
      _myPin = pin;
      _statusMessage = 'Broadcasting — keep devices close';
      _errorMessage = '';
      _discoveredHosts.clear();
    });
    _pulseCtrl.repeat();
    _startSoundPing();

    final ok = await _openSockets();
    if (ok) {
      _beaconTimer = Timer.periodic(const Duration(milliseconds: 800), (_) {
        _bcast('$_kProto:$_kBeacon:$_deviceId:$pin:$_myUsername');
      });
    } else {
      _MockBroker.register(
        p: pin,
        username: _myUsername,
        avatar: _myAvatarBase64,
      );
      _mockTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (_MockBroker.isLinked && mounted) {
          _mockTimer?.cancel();
          _onPairingComplete(
            peerUsername: _MockBroker.hostUsername ?? 'Device',
            peerAvatar: _MockBroker.hostAvatar,
            pin: pin,
          );
        }
      });
    }
  }

  String _generatePin() =>
      (Random.secure().nextInt(900000) + 100000).toString();

  void _startSoundPing() {
    _soundTimer = Timer.periodic(const Duration(milliseconds: 1200), (_) {
      SystemSound.play(SystemSoundType.click);
    });
  }

  void _onPairReq(List<String> parts, InternetAddress? senderIp) {
    if (_state != _PairingState.hosting) return;
    if (parts.length < 6) return;
    final clientDeviceId = parts[3];
    final pin = parts[4];
    final clientUsername = parts.sublist(5).join(':');
    if (clientDeviceId == _deviceId) return;
    if (pin != _myPin) return;
    _bcast(
      '$_kProto:$_kPairAck:$_deviceId:$clientDeviceId:$_myUsername',
      senderIp,
    );
    _savePeer(clientUsername, null).then((_) {
      _onPairingComplete(
        peerUsername: clientUsername,
        peerAvatar: null,
        pin: pin,
      );
    });
  }

  // =========================================================================
  // CLIENT MODE
  // =========================================================================

  Future<void> _startScanning() async {
    _shutdown();
    _isReverse = false;
    _pinFieldCtrl.clear();
    setState(() {
      _state = _PairingState.scanning;
      _enteredPin = '';
      _detectedHostName = null;
      _pendingPin = null;
      _discoveredHosts.clear();
      _statusMessage = 'Scanning for nearby devices...';
      _errorMessage = '';
    });
    _scanCtrl.repeat();
    // Auto-focus the PIN field once the screen is shown
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _pinFocus.requestFocus();
    });
    final ok = await _openSockets();
    if (!ok) _startMockScanner();
  }

  void _onBeacon(List<String> parts, InternetAddress? senderIp) {
    if (_state != _PairingState.scanning) return;
    if (parts.length < 6) return;
    final senderDeviceId = parts[3];
    final pin = parts[4];
    final username = parts.sublist(5).join(':');
    if (senderDeviceId == _deviceId) return;
    _discoveredHosts[pin] = _HostInfo(
      username: username,
      lastSeen: DateTime.now(),
      ipAddress: senderIp,
    );
    if (_detectedHostName == null) {
      setState(() {
        _detectedHostName = username;
        _statusMessage = 'Device found: $username';
      });
      Future.delayed(const Duration(milliseconds: 600), () {
        if (mounted && _state == _PairingState.scanning) {
          _initiatePairRequest(
            pin: pin,
            hostUsername: username,
            targetIp: senderIp,
          );
        }
      });
    }
  }

  void _onPairAck(List<String> parts) {
    if (_state != _PairingState.linking && _state != _PairingState.scanning) {
      return;
    }
    if (parts.length < 6) return;
    final hostDeviceId = parts[3];
    final targetClientDeviceId = parts[4];
    final hostUsername = parts.sublist(5).join(':');
    if (hostDeviceId == _deviceId) return;
    if (targetClientDeviceId != _deviceId) return;
    _reqTimer?.cancel();
    _savePeer(hostUsername, null).then((_) {
      _onPairingComplete(
        peerUsername: hostUsername,
        peerAvatar: null,
        pin: _pendingPin ?? 'error_pin',
      );
    });
  }

  void _initiatePairRequest({
    required String pin,
    required String hostUsername,
    InternetAddress? targetIp,
  }) {
    if (_state == _PairingState.linking) return;
    setState(() {
      _state = _PairingState.linking;
      _pendingPin = pin;
      _statusMessage = 'Connecting to $hostUsername...';
      _errorMessage = '';
    });
    void sendReq() =>
        _bcast('$_kProto:$_kPairReq:$_deviceId:$pin:$_myUsername', targetIp);
    sendReq();
    _reqTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_state != _PairingState.linking) {
        _reqTimer?.cancel();
        return;
      }
      sendReq();
    });
    Timer(const Duration(seconds: 20), () {
      if (mounted && _state == _PairingState.linking && _pendingPin == pin) {
        _reqTimer?.cancel();
        _showError(
          'No response from host device.\n'
          'Make sure the host app is open, showing the PIN screen, '
          'and both devices are on the same Wi-Fi network.',
        );
      }
    });
  }

  void _startMockScanner() {
    _mockTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted || _state != _PairingState.scanning) return;
      if (_MockBroker.pin == null || _MockBroker.isLinked) return;
      if (_detectedHostName == null) {
        setState(() {
          _detectedHostName = _MockBroker.hostUsername;
          _statusMessage = 'Device found: ${_MockBroker.hostUsername}';
        });
        Future.delayed(const Duration(milliseconds: 800), () {
          if (mounted && _state == _PairingState.scanning) {
            _mockTimer?.cancel();
            _executeMockLink();
          }
        });
      }
    });
  }

  // =========================================================================
  // MANUAL PIN ENTRY (keyboard-driven)
  // =========================================================================

  void _onPinFieldUpdated() {
    final value = _pinFieldCtrl.text;
    if (_state == _PairingState.linking) {
      if (value.isNotEmpty) _pinFieldCtrl.clear();
      return;
    }
    // Enforce max 6 digits
    final digits = value.replaceAll(RegExp(r'[^0-9]'), '');
    final capped = digits.length > 6 ? digits.substring(0, 6) : digits;
    
    // If there were invalid characters or it's too long, rewrite the field
    if (capped != value) {
      _pinFieldCtrl.value = TextEditingValue(
        text: capped,
        selection: TextSelection.collapsed(offset: capped.length),
      );
      return; // The listener will fire again with the corrected text
    }

    // Only update UI if the string actually changed (avoids unnecessary rebuilds)
    if (_enteredPin != capped) {
      setState(() {
        _enteredPin = capped;
        _errorMessage = '';
      });
      if (capped.length == 6) {
        _verifyPin(capped);
      }
    }
  }

  void _verifyPin(String pin) {
    final hostInfo = _discoveredHosts[pin];
    if (hostInfo != null) {
      _initiatePairRequest(
        pin: pin,
        hostUsername: hostInfo.username,
        targetIp: hostInfo.ipAddress,
      );
      return;
    }
    if (_MockBroker.pin == pin) {
      _executeMockLink();
      return;
    }
    _initiatePairRequest(pin: pin, hostUsername: 'Host Device');
  }

  // =========================================================================
  // MOCK LINK
  // =========================================================================

  void _executeMockLink() {
    _MockBroker.markLinked();
    final u = _MockBroker.hostUsername ?? 'Device';
    _savePeer(u, _MockBroker.hostAvatar).then((_) {
      _onPairingComplete(
        peerUsername: u,
        peerAvatar: _MockBroker.hostAvatar,
        pin: _MockBroker.pin ?? 'mock',
      );
    });
  }

  // =========================================================================
  // SUCCESS + PERSISTENCE
  // =========================================================================

  Future<void> _savePeer(String username, String? avatar) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('local_paired_devices') ?? [];
    if (!list.contains(username)) {
      list.add(username);
      await prefs.setStringList('local_paired_devices', list);
    }
    final reg =
        jsonDecode(prefs.getString('paired_devices_registry') ?? '{}')
            as Map<String, dynamic>;
    reg[username] = avatar;
    await prefs.setString('paired_devices_registry', jsonEncode(reg));
    
    SyncService().pushPairedDevices();
  }

  void _onPairingComplete({
    required String peerUsername,
    required String? peerAvatar,
    required String pin,
  }) {
    _shutdown();
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          peerUsername: peerUsername,
          peerAvatarBase64: peerAvatar,
        ),
      ),
    );
  }

  void _showError(String msg) {
    if (!mounted) return;
    _reqTimer?.cancel();
    setState(() {
      _state = _PairingState.scanning;
      _enteredPin = '';
      _pendingPin = null;
      _detectedHostName = null;
      _errorMessage = msg;
      _statusMessage = 'Scanning for nearby devices...';
    });
    HapticFeedback.vibrate();
  }

  // =========================================================================
  // BUILD
  // =========================================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _C.bg,
      appBar: _buildAppBar(),
      body: SafeArea(
        child: _PageSwitcher(
          transitionKey: _state.name,
          isReverse: _isReverse,
          child: _buildBody(),
        ),
      ),
    );
  }

  // ── AppBar (matches homepage style) ─────────────────────────────────────────
  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: _C.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Container(height: 1, color: _C.border),
      ),
      leading: GestureDetector(
        onTap: () {
          if (_state == _PairingState.idle || _state == _PairingState.success) {
            Navigator.pop(context);
          } else {
            _resetToIdle();
          }
        },
        child: Container(
          margin: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: _C.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _C.border),
          ),
          child: const Icon(LucideIcons.arrowLeft, color: _C.ink, size: 18),
        ),
      ),
      title: Text(
        'PAIR DEVICE',
        style: GoogleFonts.montserrat(
          fontWeight: FontWeight.w900,
          fontSize: 14,
          color: _C.ink,
          letterSpacing: 4,
        ),
      ),
      
    );
  }

  Widget _buildBody() {
    switch (_state) {
      case _PairingState.idle:
        return _buildIdleScreen(key: const ValueKey('idle'));
      case _PairingState.hosting:
        return _buildHostScreen(key: const ValueKey('host'));
      case _PairingState.scanning:
      case _PairingState.linking:
        return _buildScanScreen(key: const ValueKey('scan'));
      case _PairingState.success:
        return _buildSuccessScreen(key: const ValueKey('success'));
    }
  }

  // ---------------------------------------------------------------------------
  // IDLE / SELECTION SCREEN
  // ---------------------------------------------------------------------------

  Widget _buildIdleScreen({Key? key}) {
    return SingleChildScrollView(
      key: key,
      padding: const EdgeInsets.fromLTRB(24, 36, 24, 36),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Hero icon — editorial style with rotated square
          Center(
            child: Hero(
              tag: widget.heroTag,
              child: SizedBox(
                width: 130,
                height: 130,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Transform.rotate(
                      angle: 0.3,
                      child: Container(
                        width: 90,
                        height: 90,
                        decoration: BoxDecoration(
                          border: Border.all(color: _C.borderDk, width: 1.5),
                          borderRadius: BorderRadius.circular(22),
                        ),
                      ),
                    ),
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: _C.ink,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: const Icon(
                        LucideIcons.radio,
                        size: 30,
                        color: _C.bg,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          SizedBox(height: 5),

          // Big editorial headline
          Center(
            child: Builder(
              builder: (context) {
                final route = ModalRoute.of(context);
                final animation = route?.animation;
                final childWidget = Hero(
                  tag: 'headline_text_hero',
                  child: Material(
                    type: MaterialType.transparency,
                    child: RichText(
                      textAlign: TextAlign.center,
                      text: TextSpan(
                        children: [
                          TextSpan(
                            text: 'CONNECT\n',
                            style: GoogleFonts.montserrat(
                              fontSize: 36,
                              fontWeight: FontWeight.w900,
                              color: _C.ink,
                              letterSpacing: -2,
                              height: 0.95,
                            ),
                          ),
                          TextSpan(
                            text: 'DEVICES',
                            style: GoogleFonts.montserrat(
                              fontSize: 36,
                              fontWeight: FontWeight.w900,
                              color: _C.grey30,
                              letterSpacing: -2,
                              height: 1,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );

                if (animation == null) return childWidget;

                return AnimatedBuilder(
                  animation: animation,
                  builder: (context, child) {
                    final curve = const Interval(0.85, 1.0, curve: Curves.easeOut);
                    return Opacity(
                      opacity: curve.transform(animation.value),
                      child: child,
                    );
                  },
                  child: childWidget,
                );
              },
            ),
          ),
          SizedBox(height: 16),
          _RouteBoundEntrance(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(child: Container(height: 1, width: 48, color: _C.borderDk)),
          SizedBox(height: 16),
          Center(
            child: Text(
              'Both devices must be on the same Wi-Fi.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: _C.grey60,
                height: 1.7,
                letterSpacing: 0.2,
              ),
            ),
          ),

          SizedBox(height: 20),

          // Section label
          
          Container(height: 1, color: _C.border),
          SizedBox(height: 20),

          Row(
            children: [
              Expanded(
                child: _RoleCard(
                  icon: LucideIcons.radio,
                  label: 'BROADCAST',
                  subtitle: 'Broadcast secure code to nearby devices.',
                  tag: 'HOST',
                  onTap: _startHosting,
                ),
              ),
              SizedBox(width: 14),
              Expanded(
                child: _RoleCard(
                  icon: LucideIcons.scanLine,
                  label: 'SCAN',
                  subtitle: 'Scan or manually enter peer code.',
                  tag: 'CLIENT',
                  onTap: _startScanning,
                ),
              ),
            ],
          ),
          SizedBox(height: 32),
        ], // end inner column children
      ), // end inner column
    ), // end _RouteBoundEntrance
  ], // end outer column children
), // end outer column
); // end SingleChildScrollView
}

  // ---------------------------------------------------------------------------
  // HOST (SEND) SCREEN
  // ---------------------------------------------------------------------------

  Widget _buildHostScreen({Key? key}) {
    return SingleChildScrollView(
      key: key,
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Animated radar pulse in editorial style
          SizedBox(
            width: 200,
            height: 200,
            child: AnimatedBuilder(
              animation: _pulseCtrl,
              builder: (context, child) => RepaintBoundary(
                child: CustomPaint(
                  painter: _EditorialPulsePainter(
                    progress: _pulseCtrl.value,
                    color: _C.ink,
                  ),
                  child: child,
                ),
              ),
              child: Center(
                child: Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(
                    color: _C.ink,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: _C.ink.withValues(alpha: 0.18),
                        blurRadius: 20,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: const Icon(
                    LucideIcons.radio,
                    color: _C.bg,
                    size: 32,
                  ),
                ),
              ),
            ),
          ),
          SizedBox(height: 28),

          Text(
            _statusMessage,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: _C.grey60, height: 1.5),
          ),

          SizedBox(height: 40),

          // PIN display card
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            decoration: BoxDecoration(
              color: _C.surface,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: _C.border, width: 1.5),
            ),
            child: Column(
              children: [
                Text(
                  'PAIRING CODE',
                  style: GoogleFonts.montserrat(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2.5,
                    color: _C.grey60,
                  ),
                ),
                SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: _myPin.isEmpty
                      ? [
                          SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: _C.ink,
                            ),
                          ),
                        ]
                      : _myPin.split('').asMap().entries.map((e) {
                          
                          return Row(
                            children: [
                              
                              Container(
                                margin: const EdgeInsets.symmetric(
                                  horizontal: 3,
                                ),
                                width: 36,
                                height: 50,
                                decoration: BoxDecoration(
                                  color: _C.bg,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: _C.borderDk,
                                    width: 1.5,
                                  ),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  e.value,
                                  style: GoogleFonts.montserrat(
                                    fontSize: 24,
                                    fontWeight: FontWeight.w900,
                                    color: _C.ink,
                                    letterSpacing: -1,
                                  ),
                                ),
                              ),
                            ],
                          );
                        }).toList(),
                ),
                SizedBox(height: 14),
                Text(
                  'Share this code with the other device',
                  style: TextStyle(
                    fontSize: 11,
                    color: _C.grey30,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
          ),

          SizedBox(height: 32),

          // Info rows
          _InfoRow(
            icon: LucideIcons.wifi,
            text:
                'Auto-connect is active — the other device will pair automatically when it scans.',
          ),
          SizedBox(height: 10),
          _InfoRow(
            icon: LucideIcons.keyboard,
            text:
                'Or let the other person enter the code shown above manually.',
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // SCAN (RECEIVE + MANUAL PIN) SCREEN
  // ---------------------------------------------------------------------------

  Widget _buildScanScreen({Key? key}) {
    final isLinking = _state == _PairingState.linking;

    return SingleChildScrollView(
      key: key,
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 32),
      child: Column(
        children: [
          // Scanner animation
          SizedBox(
            width: 170,
            height: 170,
            child: AnimatedBuilder(
              animation: _scanCtrl,
              builder: (context, _) => RepaintBoundary(
                child: CustomPaint(
                  painter: _EditorialScannerPainter(
                    rotation: _scanCtrl.value * 2 * pi,
                    hasTarget: _detectedHostName != null,
                  ),
                ),
              ),
            ),
          ),

          SizedBox(height: 24),

          // Status heading + message
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            child: Column(
              key: ValueKey(_statusMessage),
              children: [
                Text(
                  _detectedHostName != null
                      ? 'DEVICE FOUND'
                      : (isLinking ? 'CONNECTING' : 'SCANNING'),
                  style: GoogleFonts.montserrat(
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    color: _detectedHostName != null ? _C.green : _C.ink,
                    letterSpacing: -0.5,
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  _statusMessage,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    color: _C.grey60,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),

          SizedBox(height: 36),

          // Divider with label
          Row(
            children: [
              Expanded(child: Container(height: 1, color: _C.border)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'ENTER PIN MANUALLY',
                  style: GoogleFonts.montserrat(
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.5,
                    color: _C.grey30,
                  ),
                ),
              ),
              Expanded(child: Container(height: 1, color: _C.border)),
            ],
          ),

          SizedBox(height: 22),

          // PIN display & hidden input
          Stack(
            alignment: Alignment.center,
            children: [
              // 1. Visual PIN dots
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(6, (i) {
                  final hasDigit = _enteredPin.length > i;
                  final digit = hasDigit ? _enteredPin[i] : '';
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: 40,
                    height: 52,
                    decoration: BoxDecoration(
                      color: hasDigit ? _C.ink : _C.surface,
                      borderRadius: BorderRadius.circular(11),
                      border: Border.all(
                        color: hasDigit ? _C.ink : _C.border,
                        width: 1.5,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      digit,
                      style: GoogleFonts.montserrat(
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        color: hasDigit ? _C.bg : _C.grey30,
                      ),
                    ),
                  );
                }),
              ),

              // 2. Invisible TextField overlay for native keyboard summoning
              Positioned.fill(
                child: TextField(
                  controller: _pinFieldCtrl,
                  focusNode: _pinFocus,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  autofocus: true,
                  showCursor: false,
                  enableInteractiveSelection: false,
                  style: GoogleFonts.montserrat(
                    fontSize: 22,
                    color: Colors.transparent, // Keeps text invisible
                  ),
                  cursorColor: Colors.transparent,
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    counterText: '',
                    fillColor: Colors.transparent,
                    filled: true,
                  ),
                ),
              ),
            ],
          ),

          
          // Error banner
          AnimatedSize(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCirc,
            child: _errorMessage.isEmpty
                ? SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: _C.red.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _C.red.withValues(alpha: 0.2),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            LucideIcons.alertTriangle,
                            size: 14,
                            color: _C.red,
                          ),
                          SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _errorMessage,
                              style: TextStyle(
                                fontSize: 12,
                                color: _C.red,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
          ),

          SizedBox(height: 24),

          if (isLinking)
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: _C.ink),
            ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // SUCCESS SCREEN
  // ---------------------------------------------------------------------------

  Widget _buildSuccessScreen({Key? key}) {
    return Center(
      key: key,
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.0, end: 1.0),
              duration: const Duration(milliseconds: 600),
              curve: Curves.elasticOut,
              builder: (context, v, _) => Transform.scale(
                scale: v,
                child: SizedBox(
                  width: 120,
                  height: 120,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Transform.rotate(
                        angle: 0.25,
                        child: Container(
                          width: 110,
                          height: 110,
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: _C.green.withValues(alpha: 0.3),
                              width: 1.5,
                            ),
                            borderRadius: BorderRadius.circular(22),
                          ),
                        ),
                      ),
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          color: _C.ink,
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: const Icon(
                          LucideIcons.checkCircle,
                          size: 32,
                          color: _C.green,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SizedBox(height: 32),
            Text(
              'LINKED',
              style: GoogleFonts.montserrat(
                fontSize: 42,
                fontWeight: FontWeight.w900,
                color: _C.ink,
                letterSpacing: -2,
              ),
            ),
            SizedBox(height: 4),
            Text(
              'SUCCESSFULLY',
              style: GoogleFonts.montserrat(
                fontSize: 42,
                fontWeight: FontWeight.w900,
                color: _C.grey30,
                letterSpacing: -2,
              ),
            ),
            SizedBox(height: 16),
            Container(height: 1, width: 48, color: _C.borderDk),
            SizedBox(height: 16),
            Text(
              _statusMessage,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: _C.grey60,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// REUSABLE WIDGETS
// =============================================================================

class _RoleCard extends StatefulWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final String tag;
  final VoidCallback onTap;

  const _RoleCard({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.tag,
    required this.onTap,
  });

  @override
  State<_RoleCard> createState() => _RoleCardState();
}

class _RoleCardState extends State<_RoleCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(18),
        height: 190,
        decoration: BoxDecoration(
          color: _pressed ? _C.ink : _C.surface,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: _pressed ? _C.ink : _C.border, width: 1.5),
          boxShadow: _pressed
              ? [
                  BoxShadow(
                    color: _C.ink.withValues(alpha: 0.15),
                    blurRadius: 20,
                    offset: const Offset(0, 10),
                  ),
                ]
              : [
                  BoxShadow(
                    color: _C.ink.withValues(alpha: 0.04),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
        ),
        child: Stack(
          children: [
            // Top Right Tag
            Align(
              alignment: Alignment.topRight,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: _pressed ? _C.bg.withValues(alpha: 0.15) : _C.border,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  widget.tag,
                  style: GoogleFonts.montserrat(
                    fontSize: Platform.isWindows?9:6,
                    fontWeight: FontWeight.w900,
                    color: _pressed ? _C.bg : _C.grey60,
                    letterSpacing: 1.5,
                  ),
                ),
              ),
            ),

            // Icon
            Align(
              alignment: Alignment.topLeft,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: _pressed ? _C.bg.withValues(alpha: 0.15) : _C.ink,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  widget.icon,
                  color: _pressed ? _C.bg : _C.bg,
                  size: 22,
                ),
              ),
            ),

            // Bottom Texts
            Align(
              alignment: Alignment.bottomLeft,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.label,
                    style: GoogleFonts.montserrat(
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                      color: _pressed ? _C.bg : _C.ink,
                      letterSpacing: -0.5,
                    ),
                  ),
                  SizedBox(height: 6),
                  Text(
                    widget.subtitle,
                    style: GoogleFonts.montserrat(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: _pressed
                          ? _C.bg.withValues(alpha: 0.7)
                          : _C.grey60,
                      height: 1.3,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String text;
  const _InfoRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: _C.grey30),
        SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 12, color: _C.grey60, height: 1.5),
          ),
        ),
      ],
    );
  }
}

// (removed — numpad replaced by system keyboard)

// =============================================================================
// PAGE SWITCHER — independent enter + exit transitions
// =============================================================================

class _PageSwitcher extends StatefulWidget {
  final String transitionKey;
  final bool isReverse;
  final Widget child;
  const _PageSwitcher({
    required this.transitionKey,
    required this.isReverse,
    required this.child,
  });

  @override
  State<_PageSwitcher> createState() => _PageSwitcherState();
}

class _PageSwitcherState extends State<_PageSwitcher>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late CurvedAnimation _curve;
  late bool _isReverse;

  late Widget _currentChild;
  Widget? _oldChild;

  @override
  void initState() {
    super.initState();
    _isReverse = widget.isReverse;
    _currentChild = widget.child;
    
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
      value: 1.0,
    );
    _curve = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutQuart);

    
  }

  @override
  void didUpdateWidget(_PageSwitcher old) {
    super.didUpdateWidget(old);
    if (old.transitionKey != widget.transitionKey) {
      _isReverse = widget.isReverse; // lock direction for this transition
      _oldChild = _currentChild;
      _currentChild = widget.child;
      _ctrl.forward(from: 0.0);
    } else {
      // Update child in place for normal state changes (e.g. typing PIN)
      _currentChild = widget.child;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final t = _curve.value; // 0 → 1

        // ── Incoming child animations ──────────────────────────────────────
        // Forward : slides up from +28px below, fades in
        // Backward: slides down from -20px above, fades in
        final inY = _isReverse ? -20.0 * (1 - t) : 28.0 * (1 - t);
        final inOpacity = t.clamp(0.0, 1.0);

        // ── Outgoing child animations ──────────────────────────────────────
        // Forward : scales 1.0→0.94, fades out fast
        // Backward: slides down +36px, fades out fast
        final outOpacity = (1.0 - t * 1.8).clamp(0.0, 1.0);
        final outScale = _isReverse ? 1.0 : (1.0 - 0.06 * t);
        final outY = _isReverse ? 36.0 * t : 0.0;

        return Stack(
          fit: StackFit.expand,
          children: [
            // Outgoing screen
            if (_oldChild != null && t < 1.0)
              Opacity(
                opacity: outOpacity,
                child: Transform.translate(
                  offset: Offset(0, outY),
                  child: Transform.scale(
                    scale: outScale,
                    alignment: Alignment.topCenter,
                    child: _oldChild,
                  ),
                ),
              ),
            // Incoming screen
            Opacity(
              opacity: inOpacity,
              child: Transform.translate(
                offset: Offset(0, inY),
                child: _currentChild,
              ),
            ),
          ],
        );
      },
    );
  }
}

// =============================================================================
// CUSTOM PAINTERS — editorial style (ink-on-cream)
// =============================================================================

class _EditorialPulsePainter extends CustomPainter {
  final double progress;
  final Color color;
  _EditorialPulsePainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = min(size.width, size.height) / 2;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    for (int i = 0; i < 4; i++) {
      final t = ((progress + i / 4.0) % 1.0);
      final r = t * maxR;
      paint.color = color.withValues(alpha: (1 - t) * 0.22);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: center, width: r * 2, height: r * 2),
          Radius.circular(r * 0.35),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_EditorialPulsePainter o) =>
      o.progress != progress || o.color != color;
}

// =============================================================================
// HELPER: ROUTE-BOUND ENTRANCE (For staggered entrance and fast exit)
// =============================================================================

class _RouteBoundEntrance extends StatelessWidget {
  final Widget child;
  const _RouteBoundEntrance({required this.child});

  @override
  Widget build(BuildContext context) {
    final route = ModalRoute.of(context);
    if (route == null || route.animation == null) return child;
    final animation = route.animation!;

    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        double opacity = 0.0;
        double yOffset = 20.0;

        if (animation.status == AnimationStatus.forward || animation.status == AnimationStatus.completed) {
          // Push: fade in and slide up during the second half of the transition
          final val = ((animation.value - 0.5) * 2.0).clamp(0.0, 1.0);
          opacity = Curves.easeOut.transform(val);
          yOffset = 20.0 * (1.0 - Curves.easeOutQuart.transform(val));
        } else {
          // Pop: fast fade out during the first 20% of the reverse transition
          // animation goes 1.0 -> 0.0
          final val = ((animation.value - 0.7) * 3.33).clamp(0.0, 1.0);
          opacity = val;
          yOffset = 20.0 * (1.0 - val);
        }

        return Opacity(
          opacity: opacity,
          child: Transform.translate(
            offset: Offset(0, yOffset),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

class _EditorialScannerPainter extends CustomPainter {
  final double rotation;
  final bool hasTarget;
  _EditorialScannerPainter({required this.rotation, this.hasTarget = false});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final r = min(size.width, size.height) / 2;
    final ink = const Color(0xFF0A0A0A);
    final accent = hasTarget ? const Color(0xFF2ECC71) : ink;

    // Concentric rings (editorial grid)
    final ringPaint = Paint()
      ..color = ink.withValues(alpha: 0.08)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawCircle(center, r, ringPaint);
    canvas.drawCircle(center, r * 0.65, ringPaint);
    canvas.drawCircle(center, r * 0.33, ringPaint);

    // Cross-hairs
    final crossPaint = Paint()
      ..color = ink.withValues(alpha: 0.08)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(center.dx - r, center.dy),
      Offset(center.dx + r, center.dy),
      crossPaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - r),
      Offset(center.dx, center.dy + r),
      crossPaint,
    );

    // Sweep gradient
    final sweepShader = SweepGradient(
      colors: [
        accent.withValues(alpha: 0.55),
        accent.withValues(alpha: 0.08),
        Colors.transparent,
      ],
      stops: const [0.0, 0.3, 1.0],
      transform: GradientRotation(rotation),
    ).createShader(Rect.fromCircle(center: center, radius: r));

    canvas.drawCircle(
      center,
      r,
      Paint()
        ..style = PaintingStyle.fill
        ..shader = sweepShader,
    );

    // Centre dot
    canvas.drawCircle(
      center,
      5,
      Paint()
        ..color = accent
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(_EditorialScannerPainter o) =>
      o.rotation != rotation || o.hasTarget != hasTarget;
}
