import 'package:google_fonts/google_fonts.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:omnidrop/chat.dart';
import 'package:omnidrop/onboarding.dart';
import 'package:omnidrop/pairing.dart';
import 'package:omnidrop/update_check_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import 'package:permission_handler/permission_handler.dart';
import 'package:omnidrop/core/p2p_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:omnidrop/core/toast_utils.dart';
import 'package:omnidrop/settings.dart';
import 'package:omnidrop/core/sync_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:omnidrop/supabase_config.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:omnidrop/channels.dart';
import 'package:omnidrop/quick_tile_tutorial.dart';
import 'package:omnidrop/core/update_service.dart';

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

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with WindowListener, TrayListener, TickerProviderStateMixin {
  String _username = 'User';
  String _displayName = 'User';
  String? _profileImageBase64;
  List<Map<String, dynamic>> _pairedDevices = [];
  bool _isLoadingDevices = true;
  Timer? _statusTimer;
  late AnimationController _fabPulse;
  late AnimationController _fadeIn;
  late Animation<double> _fadeAnim;
  late AnimationController _menuAnim;
  bool _menuOpen = false;
  StreamSubscription<P2PMessageEvent>? _p2pSubscription;
  String _appVersion = '';

  @override
  void initState() {
    super.initState();
    _loadAppVersion();
    _menuAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    _statusTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) setState(() {});
    });
    P2PManager().init();

    _fabPulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);

    _fadeIn = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fadeAnim = CurvedAnimation(parent: _fadeIn, curve: Curves.easeOut);
    _fadeIn.forward();

    _loadUserProfile();
    _loadPairedDevices();
    _requestPermissions();
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      windowManager.addListener(this);
      windowManager.setPreventClose(true);
      _initTray();
    }

    _p2pSubscription = P2PManager().eventStream.listen((event) {
      if (!mounted) return;
      if (event.isConnectionStatusUpdate && event.toastMessage != null) {
        ToastUtils.showCustomToast(
          context,
          event.toastMessage!,
          icon: LucideIcons.info,
        );
        _loadPairedDevices();
      } else if (event.isProfileUpdate) {
        _loadPairedDevices();
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showQuickTileTutorialIfNeeded();
      // Check for updates silently in the background (respects 1-day cooldown)
      UpdateService().checkForUpdates(context);
    });
  }

  Future<void> _showQuickTileTutorialIfNeeded() async {
    if (!Platform.isAndroid) return;
    final prefs = await SharedPreferences.getInstance();
    final hasSeen = prefs.getBool('has_seen_quick_tile_tutorial') ?? false;
    if (!hasSeen) {
      if (!mounted) return;

      // Delay showing the dialog to allow splash screen/route transitions to finish smoothly.
      // This prevents UI lag caused by parsing the Lottie JSON synchronously on the main thread.
      await Future.delayed(const Duration(milliseconds: 1000));
      if (!mounted) return;

      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const QuickTileTutorialDialog(),
      );
      await prefs.setBool('has_seen_quick_tile_tutorial', true);
    }
  }

  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      try {
        if (await Permission.manageExternalStorage.isDenied) {
          await Permission.manageExternalStorage.request();
        }
        if (await Permission.storage.isDenied) {
          await Permission.storage.request();
        }
      } catch (e) {
        debugPrint('Error requesting storage permissions: $e');
      }
    }
  }

  Future<void> _initTray() async {
    try {
      await trayManager.setIcon(
        Platform.isWindows ? 'assets/app_icon.ico' : 'assets/app_icon.png',
      );
      final Menu menu = Menu(
        items: [
          MenuItem(key: 'show_window', label: 'Show OmniDrop'),
          MenuItem.separator(),
          MenuItem(key: 'exit_app', label: 'Exit'),
        ],
      );
      await trayManager.setContextMenu(menu);
      trayManager.addListener(this);
    } catch (e) {
      debugPrint('Tray init failed: $e');
    }
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _fabPulse.dispose();
    _fadeIn.dispose();
    _menuAnim.dispose();
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      windowManager.removeListener(this);
      trayManager.removeListener(this);
    }
    _p2pSubscription?.cancel();
    super.dispose();
  }

  @override
  void onWindowClose() async {
    if (await windowManager.isPreventClose()) await windowManager.hide();
  }

  void _restoreWindow() {
    windowManager.show();
    windowManager.focus();
    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }

  @override
  void onTrayIconMouseDown() => _restoreWindow();
  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();
  @override
  void onTrayMenuItemClick(MenuItem item) {
    if (item.key == 'show_window') {
      _restoreWindow();
    } else if (item.key == 'exit_app') {
      windowManager.setPreventClose(false);
      windowManager.close();
    }
  }

  Future<void> _loadAppVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) setState(() => _appVersion = info.version);
  }

  Future<void> _loadUserProfile() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _username = prefs.getString('username') ?? 'User';
      _displayName = prefs.getString('display_name') ?? _username;
      _profileImageBase64 = prefs.getString('profile_image');
    });
    _loadPairedDevices();
  }

  Future<void> _loadPairedDevices() async {
    setState(() => _isLoadingDevices = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final localPaired = prefs.getStringList('local_paired_devices') ?? [];
      final registryStr = prefs.getString('paired_devices_registry') ?? '{}';
      final registry = jsonDecode(registryStr) as Map<String, dynamic>;
      final namesStr = prefs.getString('paired_devices_names') ?? '{}';
      final namesMap = jsonDecode(namesStr) as Map<String, dynamic>;

      setState(() {
        _pairedDevices = localPaired
            .map(
              (peer) => {
                'username': peer,
                'display_name': namesMap[peer] ?? peer,
                'profile_image': registry[peer] as String?,
              },
            )
            .toList();
        _isLoadingDevices = false;
      });
    } catch (e) {
      debugPrint('Error loading devices: $e');
      setState(() => _isLoadingDevices = false);
    }
  }

  void _triggerPairingFlow({String heroTag = 'radio_icon_hero'}) async {
    await Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            PairingScreen(heroTag: heroTag),
        transitionDuration: const Duration(milliseconds: 600),
        reverseTransitionDuration: const Duration(milliseconds: 500),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curve = CurvedAnimation(
            parent: animation,
            curve: Curves.easeInOutCubic,
          );
          return FadeTransition(opacity: curve, child: child);
        },
      ),
    );
    if (mounted) _loadPairedDevices();
  }

  void _showModernDialog({
    required Color iconColor,
    required String title,
    required String body,
    required String cancelLabel,
    required String confirmLabel,
    required Color confirmColor,
    required VoidCallback onConfirm,
  }) {
    showDialog(
      context: context,
      builder: (_) => BackdropFilter(
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
                BoxShadow(color: _C.ink, offset: Offset(8, 8), blurRadius: 0),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: iconColor.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    LucideIcons.alertTriangle,
                    color: iconColor,
                    size: 32,
                  ),
                ),
                SizedBox(height: 24),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.montserrat(
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                    color: _C.ink,
                    letterSpacing: 0.5,
                  ),
                ),
                SizedBox(height: 12),
                Text(
                  body,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 15,
                    color: _C.grey60,
                    height: 1.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                SizedBox(height: 32),
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
                          child: Text(
                            cancelLabel,
                            style: GoogleFonts.montserrat(
                              color: _C.ink,
                              fontWeight: FontWeight.w900,
                              fontSize: 15,
                            ),
                          ),
                        ),
                      ),
                    ),
                    SizedBox(width: 16),
                    Expanded(
                      child: GestureDetector(
                        onTap: onConfirm,
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          decoration: BoxDecoration(
                            color: confirmColor,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: _C.ink, width: 2),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            confirmLabel,
                            style: GoogleFonts.montserrat(
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
      ),
    );
  }

  void _showLogoutConfirmation() {
    _showModernDialog(
      iconColor: _C.exitdelete,
      title: 'Exit Profile',
      body: 'Are you sure you want to log out?',
      cancelLabel: 'Cancel',
      confirmLabel: 'Exit',
      confirmColor: _C.exitdelete,
      onConfirm: () async {
        final navigator = Navigator.of(context);
        P2PManager().stop();
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('username');
        navigator.pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const ProfileSetupScreen()),
          (r) => false,
        );
      },
    );
  }

  void _showDeleteConfirmation(String peer) {
    _showModernDialog(
      iconColor: _C.exitdelete,
      title: 'Remove Device',
      body:
          'Remove "$peer" from your synced channels? \nThis action cannot be undone.',
      cancelLabel: 'Cancel',
      confirmLabel: 'Remove',
      confirmColor: _C.exitdelete,
      onConfirm: () async {
        Navigator.of(context).pop();
        await _deleteDevice(peer);
      },
    );
  }

  Future<void> _deleteDevice(String username) async {
    setState(() => _isLoadingDevices = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList('local_paired_devices') ?? [];
      final registry =
          jsonDecode(prefs.getString('paired_devices_registry') ?? '{}')
              as Map<String, dynamic>;
      list.remove(username);
      registry.remove(username);
      await prefs.setStringList('local_paired_devices', list);
      await prefs.setString('paired_devices_registry', jsonEncode(registry));

      P2PManager().sendUnpairSignal(username);
      SyncService().pushPairedDevices();

      if (mounted) {
        ToastUtils.showCustomToast(
          context,
          '"$username" removed.',
          icon: LucideIcons.trash2,
        );
      }
    } catch (e) {
      debugPrint('Delete error: $e');
    } finally {
      _loadPairedDevices();
    }
  }

  // ─── Full-Screen Overlay Menu ─────────────────────────────────────────────
  void _toggleMenu() {
    setState(() => _menuOpen = !_menuOpen);
    if (_menuOpen) {
      _menuAnim.forward();
    } else {
      _menuAnim.reverse();
    }
  }

  void _closeMenu() {
    if (_menuOpen) {
      setState(() => _menuOpen = false);
      _menuAnim.reverse();
    }
  }

  Future<void> _showEditProfileDialog() async {
    final TextEditingController nameCtrl = TextEditingController(
      text: _displayName,
    );
    String? tempAvatarB64 = _profileImageBase64;

    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateModal) {
            return AlertDialog(
              backgroundColor: _C.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              title: Text(
                'Edit Profile',
                style: GoogleFonts.montserrat(
                  fontWeight: FontWeight.w900,
                  color: _C.ink,
                ),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GestureDetector(
                    onTap: () async {
                      try {
                        final result = await FilePicker.platform.pickFiles(
                          type: FileType.image,
                          withData: true,
                        );
                        if (result != null &&
                            result.files.isNotEmpty &&
                            result.files.first.bytes != null) {
                          setStateModal(() {
                            tempAvatarB64 = base64Encode(
                              result.files.first.bytes!,
                            );
                          });
                        }
                      } catch (e) {
                        debugPrint('Error picking image: $e');
                      }
                    },
                    child: Stack(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: _C.ink, width: 1.5),
                          ),
                          child: _Avatar(
                            base64: tempAvatarB64,
                            name: _username,
                            radius: 40,
                            dark: true,
                          ),
                        ),
                        Positioned(
                          bottom: 0,
                          right: 0,
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: _C.ink,
                              shape: BoxShape.circle,
                              border: Border.all(color: _C.surface, width: 2),
                            ),
                            child: const Icon(
                              LucideIcons.pencil,
                              size: 14,
                              color: _C.bg,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: 24),
                  TextField(
                    controller: nameCtrl,
                    style: GoogleFonts.montserrat(
                      fontWeight: FontWeight.bold,
                      color: _C.ink,
                    ),
                    decoration: InputDecoration(
                      labelText: 'Display Name',
                      labelStyle: GoogleFonts.montserrat(
                        color: _C.grey60,
                        fontWeight: FontWeight.bold,
                      ),
                      filled: true,
                      fillColor: _C.bg,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: const BorderSide(
                          color: _C.border,
                          width: 1.5,
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: const BorderSide(color: _C.ink, width: 2),
                      ),
                    ),
                  ),
                  SizedBox(height: 12),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(
                    'Cancel',
                    style: GoogleFonts.montserrat(
                      color: _C.grey60,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                ElevatedButton(
                  onPressed: () async {
                    final newName = nameCtrl.text.trim();
                    if (newName.isNotEmpty) {
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.reload();
                      await prefs.setString('display_name', newName);
                      if (tempAvatarB64 != null) {
                        await prefs.setString('profile_image', tempAvatarB64!);
                      }

                      setState(() {
                        _displayName = newName;
                        _profileImageBase64 = tempAvatarB64;
                      });

                      P2PManager().broadcastProfileUpdate(
                        newName,
                        tempAvatarB64,
                      );

                      if (Platform.isAndroid || Platform.isIOS) {
                        try {
                          FlutterBackgroundService().invoke('update_profile', {
                            'displayName': newName,
                            'avatar': tempAvatarB64,
                          });
                        } catch (_) {}
                      }

                      if (SupabaseConfig.isSupabaseConfigured) {
                        try {
                          await Supabase.instance.client
                              .from('profiles')
                              .update({
                                'display_name': newName,
                                'profile_image': tempAvatarB64,
                              })
                              .eq('username', _username);
                        } catch (e) {
                          debugPrint('Error updating profile on Supabase: $e');
                        }
                      }

                      if (!mounted) return;
                      Navigator.pop(context);
                      ToastUtils.showCustomToast(
                        this.context,
                        'Profile updated',
                        icon: LucideIcons.checkCircle2,
                      );
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _C.ink,
                    foregroundColor: _C.bg,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    'Save',
                    style: GoogleFonts.montserrat(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildMenuOverlay() {
    final items = [
      _OverlayMenuItem(
        index: 1,
        label: 'CHANNELS',
        sub: 'Device Details',
        icon: LucideIcons.radio,
        progress: _menuAnim,
        onTap: () {
          _closeMenu();
          Navigator.push(
            context,
            PageRouteBuilder(
              pageBuilder: (context, animation, secondaryAnimation) =>
                  const ChannelsScreen(),
              transitionsBuilder:
                  (context, animation, secondaryAnimation, child) {
                    final slide =
                        Tween<Offset>(
                          begin: const Offset(0.0, 0.06),
                          end: Offset.zero,
                        ).animate(
                          CurvedAnimation(
                            parent: animation,
                            curve: Curves.easeOutCubic,
                          ),
                        );
                    final fade = CurvedAnimation(
                      parent: animation,
                      curve: Curves.easeOut,
                    );
                    return SlideTransition(
                      position: slide,
                      child: FadeTransition(opacity: fade, child: child),
                    );
                  },
              transitionDuration: const Duration(milliseconds: 300),
              reverseTransitionDuration: const Duration(milliseconds: 250),
            ),
          );
        },
      ),
      _OverlayMenuItem(
        index: 2,
        label: 'PREFERENCES',
        sub: 'App settings',
        icon: LucideIcons.settings,
        progress: _menuAnim,
        onTap: () {
          _closeMenu();
          Navigator.push(
            context,
            PageRouteBuilder(
              pageBuilder: (context, animation, secondaryAnimation) =>
                  const SettingsScreen(),
              transitionsBuilder:
                  (context, animation, secondaryAnimation, child) {
                    final slide =
                        Tween<Offset>(
                          begin: const Offset(0.0, 0.06),
                          end: Offset.zero,
                        ).animate(
                          CurvedAnimation(
                            parent: animation,
                            curve: Curves.easeOutCubic,
                          ),
                        );
                    final fade = CurvedAnimation(
                      parent: animation,
                      curve: Curves.easeOut,
                    );
                    return SlideTransition(
                      position: slide,
                      child: FadeTransition(opacity: fade, child: child),
                    );
                  },
              transitionDuration: const Duration(milliseconds: 300),
              reverseTransitionDuration: const Duration(milliseconds: 250),
            ),
          );
        },
      ),
      _OverlayMenuItem(
        index: 3,
        label: 'UPDATE',
        sub: 'Update the app',
        icon: LucideIcons.downloadCloud,
        progress: _menuAnim,
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const UpdateCheckPage()),
          );
        },
      ),
    ];

    return AnimatedBuilder(
      animation: _menuAnim,
      builder: (context, child) {
        final curved = CurvedAnimation(
          parent: _menuAnim,
          curve: Curves.easeInOutCubic,
        ).value;
        if (curved == 0) return SizedBox.shrink();

        return Positioned.fill(
          child: GestureDetector(
            onTap: () {},
            child: ClipRect(
              child: Container(
                color: _C.bg,
                child: SafeArea(
                  child: Opacity(
                    opacity: curved,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(height: 24),

                          // Profile Block (Clean & Modern)
                          Padding(
                            padding: const EdgeInsets.only(left: 8.0),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: _C.ink,
                                      width: 1.5,
                                    ),
                                  ),
                                  child: _Avatar(
                                    base64: _profileImageBase64,
                                    name: _username,
                                    radius: 32,
                                    dark: true,
                                  ),
                                ),
                                SizedBox(width: 20),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _displayName,
                                        style: GoogleFonts.montserrat(
                                          fontSize: 26,
                                          fontWeight: FontWeight.w900,
                                          color: _C.ink,
                                          letterSpacing: 0.5,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      Text(
                                        '@$_username',
                                        style: GoogleFonts.montserrat(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w700,
                                          color: _C.grey60,
                                          letterSpacing: 0.2,
                                        ),
                                      ),
                                      SizedBox(height: 4),
                                      Row(
                                        children: [
                                          Container(
                                            width: 8,
                                            height: 8,
                                            decoration: const BoxDecoration(
                                              color: _C.onlineDot,
                                              shape: BoxShape.circle,
                                            ),
                                          ),
                                          SizedBox(width: 8),
                                          Text(
                                            'Active Now',
                                            style: GoogleFonts.montserrat(
                                              fontSize: 12,
                                              color: _C.grey60,
                                              fontWeight: FontWeight.w700,
                                              letterSpacing: 0.5,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  onPressed: _showEditProfileDialog,
                                  icon: Icon(
                                    LucideIcons.pencil,
                                    color: _C.ink,
                                    size: 20,
                                  ),
                                ),
                              ],
                            ),
                          ),

                          SizedBox(height: 40),
                          Container(height: 1, color: _C.border),
                          SizedBox(height: 32),

                          // Menu Items
                          Expanded(
                            child: ListView.separated(
                              physics: const BouncingScrollPhysics(),
                              itemCount: items.length,
                              separatorBuilder: (context, index) =>
                                  SizedBox(height: 8),
                              itemBuilder: (context, index) => items[index],
                            ),
                          ),

                          // Bottom: Logout
                          Padding(
                            padding: const EdgeInsets.only(bottom: 16.0),
                            child: GestureDetector(
                              onTap: () {
                                _closeMenu();
                                Future.delayed(
                                  const Duration(milliseconds: 300),
                                  _showLogoutConfirmation,
                                );
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 18,
                                ),
                                decoration: BoxDecoration(
                                  color: _C.surface,
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: _C.border,
                                    width: 1.5,
                                  ),
                                ),
                                alignment: Alignment.center,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      LucideIcons.logOut,
                                      color: _C.exitdelete,
                                      size: 20,
                                    ),
                                    SizedBox(width: 12),
                                    Text(
                                      'LOG OUT',
                                      style: GoogleFonts.montserrat(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w900,
                                        color: _C.exitdelete,
                                        letterSpacing: 1.5,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          if (_appVersion.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 32.0),
                              //google font montserrat
                              child: Text(
                                'OMNIDROP v$_appVersion',
                                textAlign: TextAlign.center,
                                style: GoogleFonts.montserrat(
                                  color: _C.grey60,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 1.5,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // ─── AppBar ───────────────────────────────────────────────────────────────
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
        onTap: _toggleMenu,
        child: Container(
          margin: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: _C.ink,
            borderRadius: BorderRadius.circular(10),
          ),
          child: _CustomMenuIcon(progress: _menuAnim),
        ),
      ),
      title: Row(
        children: [
          Text(
            'OMNIDROP',
            style: GoogleFonts.montserrat(
              fontWeight: FontWeight.w700,
              fontSize: 15,
              color: _C.ink,
              letterSpacing: 4,
            ),
          ),
        ],
      ),
      actions: [
        _pairedDevices.isNotEmpty
            ? IconButton(
                icon: const Icon(
                  LucideIcons.search,
                  size: 19,
                  color: _C.grey60,
                ),
                onPressed: () {},
              )
            : SizedBox.shrink(),
        SizedBox(width: 8),
      ],
    );
  }

  // ─── FAB ──────────────────────────────────────────────────────────────────
  Widget _buildFAB() {
    return AnimatedBuilder(
      animation: _fabPulse,
      builder: (_, child) => Hero(
        tag: 'fab_add_device',
        child: Container(
          decoration: BoxDecoration(
            color: _C.ink,
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color: _C.ink.withValues(alpha: 0.15 + _fabPulse.value * 0.12),
                blurRadius: 20 + _fabPulse.value * 12,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: child,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => _triggerPairingFlow(heroTag: 'fab_add_device'),
          splashColor: _C.bg.withValues(alpha: 0.1),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 22, vertical: 16),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(LucideIcons.plus, color: _C.bg, size: 18),
                  SizedBox(width: 8),
                  Text(
                    'Add Device',
                    style: GoogleFonts.montserrat(
                      color: _C.bg,
                      fontWeight: FontWeight.w900,
                      fontSize: 12,
                      letterSpacing: 2,
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

  // ─── Empty State ──────────────────────────────────────────────────────────
  Widget _buildEmptyStateView() {
    return FadeTransition(
      opacity: _fadeAnim,
      child: Center(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Decorative stacked squares (editorial style) - HERO ANIMATED
                Hero(
                  tag: 'radio_icon_hero',
                  flightShuttleBuilder:
                      (
                        flightContext,
                        animation,
                        flightDirection,
                        fromHeroContext,
                        toHeroContext,
                      ) {
                        return AnimatedBuilder(
                          animation: animation,
                          builder: (context, child) {
                            double fromOpacity = 0.0;
                            double toOpacity = 0.0;
                            final val = animation.value;

                            if (flightDirection == HeroFlightDirection.push) {
                              fromOpacity = (1.0 - (val * 2.5)).clamp(0.0, 1.0);
                              toOpacity = ((val - 0.5) * 2.0).clamp(0.0, 1.0);
                            } else {
                              fromOpacity = ((val - 0.5) * 2.0).clamp(0.0, 1.0);
                              toOpacity = (1.0 - (val * 2.5)).clamp(0.0, 1.0);
                            }

                            return Stack(
                              alignment: Alignment.center,
                              fit: StackFit.expand,
                              children: [
                                Opacity(
                                  opacity: fromOpacity,
                                  child: FittedBox(
                                    fit: BoxFit.contain,
                                    child: fromHeroContext.widget,
                                  ),
                                ),
                                Opacity(
                                  opacity: toOpacity,
                                  child: FittedBox(
                                    fit: BoxFit.contain,
                                    child: toHeroContext.widget,
                                  ),
                                ),
                              ],
                            );
                          },
                        );
                      },
                  child: SizedBox(
                    width: 120,
                    height: 120,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        // Outer rotated square
                        Transform.rotate(
                          angle: 0.3,
                          child: Container(
                            width: 100,
                            height: 100,
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: _C.borderDk,
                                width: 1.5,
                              ),
                              borderRadius: BorderRadius.circular(20),
                            ),
                          ),
                        ),
                        // Inner
                        Container(
                          width: 68,
                          height: 68,
                          decoration: BoxDecoration(
                            color: _C.ink,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: const Icon(
                            LucideIcons.radio,
                            size: 28,
                            color: _C.bg,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(height: 44),
                // Editorial-style big headline
                Hero(
                  tag: 'headline_text_hero',
                  flightShuttleBuilder:
                      (
                        flightContext,
                        animation,
                        flightDirection,
                        fromHeroContext,
                        toHeroContext,
                      ) {
                        return AnimatedBuilder(
                          animation: animation,
                          builder: (context, child) {
                            double fromOpacity = 0.0;
                            double toOpacity = 0.0;
                            final val = animation.value;

                            if (flightDirection == HeroFlightDirection.push) {
                              // Push: val goes 0.0 -> 1.0
                              fromOpacity = (1.0 - (val * 2.5)).clamp(0.0, 1.0);
                              toOpacity = ((val - 0.5) * 2.0).clamp(0.0, 1.0);
                            } else {
                              // Pop: val goes 1.0 -> 0.0
                              // fromHero is the outgoing screen (Pairing)
                              // toHero is the incoming screen (Home)
                              fromOpacity = ((val - 0.5) * 2.0).clamp(0.0, 1.0);
                              toOpacity = (1.0 - (val * 2.5)).clamp(0.0, 1.0);
                            }

                            return Stack(
                              alignment: Alignment.center,
                              fit: StackFit.expand,
                              children: [
                                Opacity(
                                  opacity: fromOpacity,
                                  child: FittedBox(
                                    fit: BoxFit.contain,
                                    child: fromHeroContext.widget,
                                  ),
                                ),
                                Opacity(
                                  opacity: toOpacity,
                                  child: FittedBox(
                                    fit: BoxFit.contain,
                                    child: toHeroContext.widget,
                                  ),
                                ),
                              ],
                            );
                          },
                        );
                      },
                  child: Material(
                    type: MaterialType.transparency,
                    child: RichText(
                      textAlign: TextAlign.center,
                      text: TextSpan(
                        children: [
                          TextSpan(
                            text: 'NO\n',
                            style: GoogleFonts.montserrat(
                              fontSize: 52,
                              fontWeight: FontWeight.w900,
                              color: _C.ink,
                              letterSpacing: -2,
                              height: 0.95,
                            ),
                          ),
                          TextSpan(
                            text: 'DEVICES',
                            style: GoogleFonts.montserrat(
                              fontSize: 52,
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
                ),
                SizedBox(height: 20),
                // Thin rule
                Container(height: 1, width: 48, color: _C.borderDk),
                SizedBox(height: 20),
                Text(
                  'Bring another device nearby\nto begin an over-the-air link.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    color: _C.grey60,
                    height: 1.7,
                    letterSpacing: 0.2,
                  ),
                ),
                SizedBox(height: 44),
                GestureDetector(
                  onTap: _triggerPairingFlow,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 17,
                    ),
                    decoration: BoxDecoration(
                      color: _C.ink,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(LucideIcons.zap, color: _C.bg, size: 15),
                        SizedBox(width: 10),
                        Text(
                          'PAIR A DEVICE',
                          style: GoogleFonts.montserrat(
                            color: _C.bg,
                            fontWeight: FontWeight.w800,
                            fontSize: 13,
                            letterSpacing: 2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ─── Device List ──────────────────────────────────────────────────────────
  Widget _buildDeviceChannelListView() {
    return FadeTransition(
      opacity: _fadeAnim,
      child: CustomScrollView(
        slivers: [
          // Device tiles
          SliverPadding(
            padding: const EdgeInsets.only(top: 20, bottom: 120),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                final device = _pairedDevices[index];
                final peer = device['username'] as String? ?? 'Peer';
                final displayName = device['display_name'] as String? ?? peer;
                final avatarB64 = device['profile_image'] as String?;
                final isOnline = P2PManager().isPeerOnline(peer);
                return _DeviceTile(
                  peerUsername: peer,
                  displayName: displayName,
                  avatarBase64: avatarB64,
                  isOnline: isOnline,
                  index: index,
                  onTap: () => Navigator.push(
                    context,
                    PageRouteBuilder(
                      pageBuilder: (context, animation, secondaryAnimation) =>
                          ChatScreen(
                            peerUsername: peer,
                            displayName: displayName,
                            peerAvatarBase64: avatarB64,
                          ),
                      transitionDuration: const Duration(milliseconds: 400),
                      reverseTransitionDuration: const Duration(
                        milliseconds: 400,
                      ),
                      transitionsBuilder:
                          (context, animation, secondaryAnimation, child) {
                            final slideAnimation =
                                Tween<Offset>(
                                  begin: const Offset(1.0, 0.0),
                                  end: Offset.zero,
                                ).animate(
                                  CurvedAnimation(
                                    parent: animation,
                                    curve: Curves.easeOutCubic,
                                    reverseCurve: Curves.easeInCubic,
                                  ),
                                );

                            return SlideTransition(
                              position: slideAnimation,
                              child: child,
                            );
                          },
                    ),
                  ),
                  onLongPress: () => _showDeleteConfirmation(peer),
                  onDelete: () => _showDeleteConfirmation(peer),
                );
              }, childCount: _pairedDevices.length),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Build ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _C.bg,
      appBar: _buildAppBar(),
      body: Stack(
        children: [
          // Main content
          _isLoadingDevices
              ? Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      color: _C.ink,
                      strokeWidth: 2,
                    ),
                  ),
                )
              : (_pairedDevices.isEmpty
                    ? _buildEmptyStateView()
                    : _buildDeviceChannelListView()),
          // Overlay menu on top
          _buildMenuOverlay(),
        ],
      ),
      floatingActionButton: _pairedDevices.isEmpty
          ? null
          : AnimatedBuilder(
              animation: _menuAnim,
              builder: (_, child) => IgnorePointer(
                ignoring: _menuOpen,
                child: AnimatedOpacity(
                  opacity: _menuOpen ? 0.0 : 1.0,
                  duration: const Duration(milliseconds: 200),
                  child: child,
                ),
              ),
              child: _buildFAB(),
            ),
    );
  }
}

// ─── Overlay Menu Item ────────────────────────────────────────────────────────
class _OverlayMenuItem extends StatelessWidget {
  const _OverlayMenuItem({
    required this.index,
    required this.label,
    required this.sub,
    required this.icon,
    required this.progress,
    required this.onTap,
  });
  final int index;
  final String label;
  final String sub;
  final IconData icon;
  final Animation<double> progress;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: progress,
      builder: (context, child) {
        final delay = (index * 0.12).clamp(0.0, 0.6);
        final start = delay;
        final end = (delay + 0.5).clamp(0.0, 1.0);
        final t = ((progress.value - start) / (end - start)).clamp(0.0, 1.0);
        final curved = Curves.easeOutCubic.transform(t);
        return Transform.translate(
          offset: Offset(0, 40 * (1 - curved)),
          child: Opacity(opacity: curved, child: child),
        );
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12.0),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: const BoxDecoration(
                  color: _C.ink,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: _C.bg, size: 24),
              ),
              SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      label,
                      style: GoogleFonts.montserrat(
                        fontSize: 26,
                        fontWeight: FontWeight.w900,
                        color: _C.ink,
                        letterSpacing: -0.5,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      sub,
                      style: GoogleFonts.montserrat(
                        fontSize: 12,
                        color: _C.grey60,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Avatar ──────────────────────────────────────────────────────────────────
class _Avatar extends StatelessWidget {
  const _Avatar({
    required this.base64,
    required this.name,
    this.radius = 22,
    this.dark = true,
  });
  final String? base64;
  final String name;
  final double radius;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: radius,
      backgroundColor: dark ? _C.surface : const Color(0xFF1A1A1A),
      backgroundImage: base64 != null
          ? MemoryImage(base64Decode(base64!))
          : null,
      child: base64 == null
          ? Text(
              name.isNotEmpty ? name[0].toUpperCase() : 'U',
              style: GoogleFonts.montserrat(
                fontSize: radius * 0.72,
                fontWeight: FontWeight.w900,
                color: dark ? _C.ink : _C.bg,
                letterSpacing: 0.5,
              ),
            )
          : null,
    );
  }
}

// ─── Device Tile ─────────────────────────────────────────────────────────────
class _DeviceTile extends StatefulWidget {
  const _DeviceTile({
    required this.peerUsername,
    required this.displayName,
    required this.avatarBase64,
    required this.isOnline,
    required this.index,
    required this.onTap,
    required this.onLongPress,
    required this.onDelete,
  });
  final String peerUsername;
  final String displayName;
  final String? avatarBase64;
  final bool isOnline;
  final int index;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onDelete;

  @override
  State<_DeviceTile> createState() => _DeviceTileState();
}

class _DeviceTileState extends State<_DeviceTile>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<Offset> _slide;
  late Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 400 + widget.index * 60),
    );
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.15),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    Future.delayed(Duration(milliseconds: widget.index * 60), () {
      if (mounted) _ctrl.forward();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: _slide,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
          decoration: BoxDecoration(
            color: _C.ink,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: widget.isOnline
                  ? _C.ink.withValues(alpha: 0.15)
                  : _C.border,
              width: 1,
            ),
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(18),
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: widget.onTap,
              onLongPress: widget.onLongPress,
              splashColor: _C.ink.withValues(alpha: 0.04),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    // Avatar + online indicator
                    Stack(
                      children: [
                        Hero(
                          tag: 'avatar_${widget.peerUsername}',
                          child: Container(
                            padding: const EdgeInsets.all(2.5),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: widget.isOnline
                                    ? _C.onlineDot
                                    : _C.border,
                                width: 1.5,
                              ),
                            ),
                            child: _Avatar(
                              base64: widget.avatarBase64,
                              name: widget.displayName,
                              radius: 22,
                              dark: true,
                            ),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(width: 14),

                    // Text info
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.displayName,
                            style: GoogleFonts.montserrat(
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                              color: _C.surface,
                              letterSpacing: 0.5,
                            ),
                          ),
                          SizedBox(height: 2),
                          Row(
                            children: [
                              Text(
                                widget.isOnline ? 'Connected' : 'Offline',
                                style: GoogleFonts.montserrat(
                                  fontSize: 11,
                                  color: widget.isOnline
                                      ? _C.onlineDot
                                      : _C.grey30,
                                  letterSpacing: 0.1,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    GestureDetector(
                      onTap: widget.onDelete,
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: _C.exitdelete.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: _C.exitdelete.withValues(alpha: 0.2),
                            width: 1,
                          ),
                        ),
                        child: const Icon(
                          LucideIcons.trash2,
                          size: 16,
                          color: _C.exitdelete,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Custom Animated Icons ───────────────────────────────────────────────────
class _CustomMenuIcon extends StatelessWidget {
  const _CustomMenuIcon({required this.progress});
  final Animation<double> progress;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: progress,
      builder: (context, child) {
        final val = CurvedAnimation(
          parent: progress,
          curve: Curves.easeInOutCubic,
        ).value;
        return SizedBox(
          width: 24,
          height: 24,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Transform.translate(
                offset: Offset(0, -4 * (1 - val)),
                child: Transform.rotate(
                  angle: val * (3.14159265359 / 4),
                  child: Container(
                    width: 14,
                    height: 2,
                    decoration: BoxDecoration(
                      color: _C.bg,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
              Transform.translate(
                offset: Offset((1 - val) * -3, 4 * (1 - val)),
                child: Transform.rotate(
                  angle: val * (-3.14159265359 / 4),
                  child: Container(
                    width: 14 - (6 * (1 - val)),
                    height: 2,
                    decoration: BoxDecoration(
                      color: _C.bg,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
