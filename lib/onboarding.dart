import 'package:google_fonts/google_fonts.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:omnidrop/homepage.dart';
import 'package:omnidrop/supabase_config.dart';
import 'package:omnidrop/core/toast_utils.dart';
import 'package:omnidrop/core/sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
// ─── Design Tokens (Cream × Black editorial palette) ─────────────────────────
class _C {
  static const bg = Color(0xFFF5F0E8);
  static const surface = Color(0xFFEDE8DF);
  static const ink = Color(0xFF0A0A0A);
  static const border = Color(0xFFD4CEC4);
  static const grey60 = Color(0xFF8A8278);
  static const onlineDot = Color(0xFF2ECC71);
}

class ProfileSetupScreen extends StatefulWidget {
  const ProfileSetupScreen({super.key});

  @override
  State<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends State<ProfileSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController = TextEditingController();

  bool _isSignUpMode = true;
  bool _isLoading = false;
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;

  Uint8List? _avatarBytes;
  String? _base64Avatar;

  Timer? _debounce;
  bool _isChecking = false;
  bool? _isAvailable;
  String? _validationError;
  List<String> _suggestions = [];

  static const List<String> _takenUsernames = [
    'sanjeev_nair',
    'john_doe',
    'alice',
    'bob',
    'omnidrop',
    'nexus',
    'aurora',
    'matrix',
    'quantum',
  ];

  @override
  void initState() {
    super.initState();
    _usernameController.addListener(_onUsernameChanged);
  }

  @override
  void dispose() {
    _usernameController.removeListener(_onUsernameChanged);
    _usernameController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onUsernameChanged() {
    // Only check username uniqueness in Sign Up mode
    if (!_isSignUpMode) return;

    // Cancel any active debounce timer before early returns
    if (_debounce?.isActive ?? false) _debounce!.cancel();

    final text = _usernameController.text.trim().toLowerCase();
    if (text.isEmpty) {
      setState(() {
        _isChecking = false;
        _isAvailable = null;
        _validationError = null;
        _suggestions = [];
      });
      return;
    }

    if (!RegExp(r'^[a-z0-9._]+$').hasMatch(text)) {
      setState(() {
        _isChecking = false;
        _isAvailable = false;
        _validationError = 'Only lowercase letters, numbers, dots (.), and underscores (_) are allowed';
        _suggestions = [];
      });
      return;
    }

    if (text.length < 4) {
      setState(() {
        _isChecking = false;
        _isAvailable = false;
        _validationError = 'Username must be at least 4 characters';
        _suggestions = [];
      });
      return;
    }

    if (text.length > 16) {
      setState(() {
        _isChecking = false;
        _isAvailable = false;
        _validationError = 'Username must be at most 16 characters';
        _suggestions = [];
      });
      return;
    }

    _debounce = Timer(const Duration(milliseconds: 500), () {
      _verifyUsername(text);
    });
  }

  Future<void> _verifyUsername(String username) async {
    setState(() {
      _isChecking = true;
      _validationError = null;
      _isAvailable = null;
      _suggestions = [];
    });

    if (SupabaseConfig.isSupabaseConfigured) {
      try {
        final client = Supabase.instance.client;
        final response = await client
            .from('profiles')
            .select('username')
            .eq('username', username)
            .maybeSingle()
            .timeout(const Duration(seconds: 3));
            
        if (!mounted) return;
        if (username != _usernameController.text.trim().toLowerCase()) return;
        
        final isTaken = response != null;
        setState(() {
          _isChecking = false;
          if (isTaken) {
            _isAvailable = false;
            _validationError = 'Username is already taken on another device';
            final rand = Random();
            final suffixes = ['dot', 'usr', 'dev', 'pro', 'net', 'app', 'hub', 'sys'];
            final rawSuggestions = [
              '$username.${suffixes[rand.nextInt(suffixes.length)]}',
              '${username}_${rand.nextInt(90) + 10}',
              '${username}99',
              '${username}_dev',
            ];
            _suggestions = rawSuggestions
                .map((s) => s.length > 16 ? s.substring(0, 16) : s)
                .toSet()
                .toList();
          } else {
            _isAvailable = true;
            _validationError = null;
          }
        });
        return;
      } catch (e) {
        debugPrint('Supabase username check error, falling back to mock: $e');
      }
    }

    // Fallback to local list check
    await Future.delayed(const Duration(milliseconds: 400));
    if (!mounted) return;
    if (username != _usernameController.text.trim().toLowerCase()) return;

    final isTaken = _takenUsernames.contains(username);
    setState(() {
      _isChecking = false;
      if (isTaken) {
        _isAvailable = false;
        _validationError = 'Username is already taken on another device';
        final rand = Random();
        final suffixes = ['dot', 'usr', 'dev', 'pro', 'net', 'app', 'hub', 'sys'];
        final rawSuggestions = [
          '$username.${suffixes[rand.nextInt(suffixes.length)]}',
          '${username}_${rand.nextInt(90) + 10}',
          '${username}99',
          '${username}_dev',
        ];
        _suggestions = rawSuggestions
            .map((s) => s.length > 16 ? s.substring(0, 16) : s)
            .toSet()
            .toList();
      } else {
        _isAvailable = true;
        _validationError = null;
      }
    });
  }

  Future<void> _pickAvatar() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
        withData: true,
      );

      if (result != null && result.files.isNotEmpty) {
        final file = result.files.first;
        final bytes = file.bytes;
        
        if (bytes != null) {
          setState(() {
            _avatarBytes = bytes;
            _base64Avatar = base64Encode(bytes);
          });
        }
      }
    } catch (e) {
      debugPrint('Error picking avatar: $e');
      if (mounted) {
        ToastUtils.showCustomToast(context, 'Failed to pick avatar image', icon: LucideIcons.xCircle);
      }
    }
  }

  void _handleSubmit() async {
    if (!_formKey.currentState!.validate()) return;

    final username = _usernameController.text.trim().toLowerCase();
    final password = _passwordController.text;

    setState(() => _isLoading = true);

    if (_isSignUpMode) {
      if (password != _confirmPasswordController.text) {
        setState(() => _isLoading = false);
        ToastUtils.showCustomToast(context, 'Passwords do not match', icon: LucideIcons.xCircle);
        return;
      }

      if (_isAvailable == false) {
        setState(() => _isLoading = false);
        ToastUtils.showCustomToast(context, _validationError ?? 'Username is taken', icon: LucideIcons.xCircle);
        return;
      }

      final hashedPassword = sha256.convert(utf8.encode(password)).toString();

      if (SupabaseConfig.isSupabaseConfigured) {
        try {
          await Supabase.instance.client.from('profiles').insert({
            'username': username,
            'password': hashedPassword,
            'profile_image': _base64Avatar,
          });
        } catch (e) {
          debugPrint('Sign up insertion failed: $e');
          if (mounted) {
            setState(() => _isLoading = false);
            ToastUtils.showCustomToast(context, 'Sign up failed', icon: LucideIcons.xCircle);
          }
          return;
        }
      } else {
        await Future.delayed(const Duration(milliseconds: 850));
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('username', username);
      await prefs.setString('display_name', username);
      if (_base64Avatar != null) {
        await prefs.setString('profile_image', _base64Avatar!);
      } else {
        await prefs.remove('profile_image');
      }

      await SyncService().restoreBackup(username);

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const HomeScreen()),
        );
      }
    } else {
      final hashedPassword = sha256.convert(utf8.encode(password)).toString();
      String? profileImageBase64;

      if (SupabaseConfig.isSupabaseConfigured) {
        try {
          final response = await Supabase.instance.client
              .from('profiles')
              .select()
              .eq('username', username)
              .maybeSingle();

          if (!mounted) return;

          if (response == null) {
            setState(() => _isLoading = false);
            ToastUtils.showCustomToast(context, 'Username not found', icon: LucideIcons.xCircle);
            return;
          }

          final dbPassword = response['password'] as String;
          if (dbPassword != hashedPassword) {
            setState(() => _isLoading = false);
            ToastUtils.showCustomToast(context, 'Invalid password', icon: LucideIcons.xCircle);
            return;
          }

          profileImageBase64 = response['profile_image'] as String?;
        } catch (e) {
          debugPrint('Login check failed: $e');
          if (mounted) {
            setState(() => _isLoading = false);
            ToastUtils.showCustomToast(context, 'Login failed', icon: LucideIcons.xCircle);
          }
          return;
        }
      } else {
        await Future.delayed(const Duration(milliseconds: 850));
        
        if (!mounted) return;

        if (_takenUsernames.contains(username)) {
          final mockCorrectPassword = username == 'sanjeev_nair' ? 'password123' : 'john123';
          if (password != mockCorrectPassword) {
            setState(() => _isLoading = false);
            ToastUtils.showCustomToast(context, 'Invalid password for mock account', icon: LucideIcons.xCircle);
            return;
          }
        }
        profileImageBase64 = null;
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('username', username);
      if (prefs.getString('display_name') == null) {
        await prefs.setString('display_name', username);
      }
      if (profileImageBase64 != null) {
        await prefs.setString('profile_image', profileImageBase64);
      } else {
        await prefs.remove('profile_image');
      }

      await SyncService().restoreBackup(username);

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const HomeScreen()),
        );
      }
    }
  }

  Widget _buildModeSelector() {
    return Container(
      decoration: BoxDecoration(
        color: _C.surface,
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: _C.border, width: 1.5),
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () {
                if (!_isSignUpMode) {
                  setState(() {
                    _isSignUpMode = true;
                    _formKey.currentState?.reset();
                    _usernameController.clear();
                    _passwordController.clear();
                    _confirmPasswordController.clear();
                    _validationError = null;
                    _isAvailable = null;
                    _suggestions = [];
                  });
                }
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: _isSignUpMode ? _C.ink : Colors.transparent,
                  borderRadius: BorderRadius.circular(26),
                ),
                alignment: Alignment.center,
                child: Text(
                  'Sign Up',
                  style: GoogleFonts.montserrat(
                    fontWeight: FontWeight.bold,
                    color: _isSignUpMode ? _C.bg : _C.grey60,
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: GestureDetector(
              onTap: () {
                if (_isSignUpMode) {
                  setState(() {
                    _isSignUpMode = false;
                    _formKey.currentState?.reset();
                    _usernameController.clear();
                    _passwordController.clear();
                    _confirmPasswordController.clear();
                    _validationError = null;
                    _isAvailable = null;
                    _suggestions = [];
                  });
                }
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: !_isSignUpMode ? _C.ink : Colors.transparent,
                  borderRadius: BorderRadius.circular(26),
                ),
                alignment: Alignment.center,
                child: Text(
                  'Log In',
                  style: GoogleFonts.montserrat(
                    fontWeight: FontWeight.bold,
                    color: !_isSignUpMode ? _C.bg : _C.grey60,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color.fromARGB(255, 245, 240, 232),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32.0),
          child: SizedBox(
            width: 400,
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // App Branding Identity
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      Image.asset('assets/OMNIDROP_icon_with_title-Photoroom.png', width: 150, height: 150),
                      // Text(
                      //   'OMNIDROP',
                      //   style: GoogleFonts.montserrat(fontSize: 24, fontWeight: FontWeight.w900, color: _C.ink, letterSpacing: 2),
                      // ),
                      
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        transitionBuilder: (Widget child, Animation<double> animation) {
                          return SlideTransition(
                            position: Tween<Offset>(
                              begin: const Offset(0.0, 0.5),
                              end: Offset.zero,
                            ).animate(animation),
                            child: FadeTransition(
                              opacity: animation,
                              child: child,
                            ),
                          );
                        },
                        child: Container(
                          margin: const EdgeInsets.only(top: 130),
                          child: Text(
                            _isSignUpMode 
                              ? 'Create your identity to start sharing.'
                              : 'Sign in to resume sharing.',
                            key: ValueKey<bool>(_isSignUpMode),
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 13, color: _C.grey60, height: 1.4, fontWeight: FontWeight.w500),
                          ),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 24),

                  // Supabase Config Warning Banner
                  if (!SupabaseConfig.isSupabaseConfigured) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.amber.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.amber),
                      ),
                      child: Row(
                        children: [
                          const Icon(LucideIcons.alertTriangle, color: Colors.amber, size: 18),
                          SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Running in local sandbox mode. Configure "lib/supabase_config.dart" to connect your live Supabase DB.',
                              style: GoogleFonts.montserrat(color: Colors.amber.shade900, fontSize: 12, height: 1.3, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: 24),
                  ],

                  // Tab Selector
                  _buildModeSelector(),
                  SizedBox(height: 32),

                  // Avatar Picker (Sign Up Mode Only)
                  AnimatedSize(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOut,
                    alignment: Alignment.topCenter,
                    child: _isSignUpMode
                        ? Column(
                            children: [
                              GestureDetector(
                                onTap: _pickAvatar,
                                behavior: HitTestBehavior.opaque,
                                child: Column(
                                  children: [
                                    Stack(
                                      children: [
                                        Container(
                                          width: 100,
                                          height: 100,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: _C.surface,
                                            border: Border.all(color: _C.border, width: 1.5),
                                            image: _avatarBytes != null 
                                              ? DecorationImage(image: MemoryImage(_avatarBytes!), fit: BoxFit.cover)
                                              : null,
                                          ),
                                          child: _avatarBytes == null
                                              ? const Icon(LucideIcons.user, size: 40, color: _C.grey60)
                                              : null,
                                        ),
                                        Positioned(
                                          bottom: 0,
                                          right: 0,
                                          child: Container(
                                            padding: const EdgeInsets.all(8),
                                            decoration: BoxDecoration(
                                              color: _C.ink, 
                                              shape: BoxShape.circle,
                                              border: Border.all(color: _C.bg, width: 2),
                                            ),
                                            child: const Icon(LucideIcons.camera, size: 16, color: _C.bg),
                                          ),
                                        ),
                                      ],
                                    ),
                                    SizedBox(height: 12),
                                    Text(
                                      _avatarBytes == null 
                                          ? 'Set profile image'
                                          : 'Change profile image',
                                      style: GoogleFonts.montserrat(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                        color: _C.grey60,
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              SizedBox(height: 32),
                            ],
                          )
                        : SizedBox.shrink(),
                  ),

                  // Unique Username Input field
                  TextFormField(
                    controller: _usernameController,
                    style: GoogleFonts.montserrat(color: _C.ink, fontWeight: FontWeight.bold),
                    inputFormatters: [
                      LengthLimitingTextInputFormatter(16),
                      FilteringTextInputFormatter.allow(RegExp(r'[a-z0-9._]')),
                    ],
                    validator: (val) {
                      if (val == null || val.trim().isEmpty) return 'Username is mandatory';
                      if (val.length < 4) return 'Username must be at least 4 characters';
                      if (val.length > 16) return 'Username must be at most 16 characters';
                      if (!RegExp(r'^[a-z0-9._]+$').hasMatch(val)) {
                        return 'Only lowercase letters, numbers, dots (.), and underscores (_) are allowed';
                      }
                      return null;
                    },
                    decoration: InputDecoration(
                      labelText: 'Username',
                      labelStyle: GoogleFonts.montserrat(color: _C.grey60, fontWeight: FontWeight.bold),
                      prefixIcon: const Icon(LucideIcons.atSign, size: 18, color: _C.grey60),
                      suffixIcon: _isSignUpMode
                          ? (_isChecking
                              ? Container(
                                  width: 20,
                                  height: 20,
                                  padding: const EdgeInsets.all(16),
                                  child: const CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: _C.ink,
                                  ),
                                )
                              : _isAvailable == true
                                  ? const Icon(LucideIcons.checkCircle2, color: _C.onlineDot, size: 20)
                                  : _isAvailable == false
                                      ? const Icon(LucideIcons.alertCircle, color: Colors.redAccent, size: 20)
                                      : null)
                          : null,
                      hintStyle: TextStyle(color: _C.grey60.withValues(alpha: 0.5)),
                      filled: true,
                      fillColor: _C.surface,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: const BorderSide(color: _C.border, width: 1.5),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: const BorderSide(color: _C.border, width: 1.5),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: const BorderSide(color: _C.ink, width: 2),
                      ),
                      floatingLabelBehavior: FloatingLabelBehavior.never,
                    ),
                  ),

                  // Username validation messages & suggestions
                  AnimatedSize(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOut,
                    alignment: Alignment.topCenter,
                    child: _isSignUpMode
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (_validationError != null) ...[
                                SizedBox(height: 8),
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 4),
                                  child: Row(
                                    children: [
                                      const Icon(LucideIcons.xCircle, size: 16, color: Colors.redAccent),
                                      SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          _validationError!,
                                          style: GoogleFonts.montserrat(color: Colors.redAccent, fontSize: 13, fontWeight: FontWeight.bold),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ] else if (_isAvailable == true) ...[
                                SizedBox(height: 8),
                                Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 4),
                                  child: Row(
                                    children: [
                                      Icon(LucideIcons.checkCircle2, size: 16, color: _C.onlineDot),
                                      SizedBox(width: 8),
                                      Text(
                                        'Username is available!',
                                        style: GoogleFonts.montserrat(color: _C.onlineDot, fontSize: 13, fontWeight: FontWeight.bold),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
          
                              if (_suggestions.isNotEmpty) ...[
                                SizedBox(height: 16),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 4),
                                    child: Text(
                                      'Available suggestions:',
                                      style: GoogleFonts.montserrat(fontSize: 12, color: _C.grey60, fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                ),
                                SizedBox(height: 8),
                                SizedBox(
                                  height: 38,
                                  child: ListView.separated(
                                    scrollDirection: Axis.horizontal,
                                    itemCount: _suggestions.length,
                                    separatorBuilder: (context, index) => SizedBox(width: 8),
                                    itemBuilder: (context, index) {
                                      final suggestion = _suggestions[index];
                                      return ActionChip(
                                        label: Text(suggestion),
                                        labelStyle: GoogleFonts.montserrat(color: _C.ink, fontWeight: FontWeight.bold, fontSize: 13),
                                        backgroundColor: _C.bg,
                                        padding: const EdgeInsets.symmetric(horizontal: 10),
                                        side: const BorderSide(color: _C.border, width: 1.5),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                        onPressed: () {
                                          _usernameController.text = suggestion;
                                          _usernameController.selection = TextSelection.fromPosition(
                                            TextPosition(offset: suggestion.length),
                                          );
                                        },
                                      );
                                    },
                                  ),
                                ),
                              ],
                            ],
                          )
                        : SizedBox.shrink(),
                  ),
                  SizedBox(height: 16),

                  // Password Field
                  TextFormField(
                    controller: _passwordController,
                    obscureText: _obscurePassword,
                    style: GoogleFonts.montserrat(color: _C.ink, fontWeight: FontWeight.bold),
                    validator: (val) {
                      if (val == null || val.isEmpty) return 'Password is mandatory';
                      if (_isSignUpMode) {
                        if (val.length < 8) {
                          return 'Password must be at least 8 characters';
                        }
                        if (!RegExp(r'[A-Z]').hasMatch(val)) {
                          return 'Password must contain at least one uppercase letter';
                        }
                        if (!RegExp(r'[0-9]').hasMatch(val)) {
                          return 'Password must contain at least one number';
                        }
                        if (!RegExp(r'[!@#\$%^&*(),.?":{}|<>]').hasMatch(val)) {
                          return 'Password must contain at least one special character';
                        }
                      }
                      return null;
                    },
                    decoration: InputDecoration(
                      labelText: 'Password',
                      labelStyle: GoogleFonts.montserrat(color: _C.grey60, fontWeight: FontWeight.bold),
                      prefixIcon: const Icon(LucideIcons.lock, size: 18, color: _C.grey60),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscurePassword ? LucideIcons.eyeOff : LucideIcons.eye,
                          size: 18,
                          color: _C.grey60,
                        ),
                        onPressed: () {
                          setState(() {
                            _obscurePassword = !_obscurePassword;
                          });
                        },
                      ),
                      filled: true,
                      fillColor: _C.surface,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: const BorderSide(color: _C.border, width: 1.5),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: const BorderSide(color: _C.border, width: 1.5),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: const BorderSide(color: _C.ink, width: 2),
                      ),
                      floatingLabelBehavior: FloatingLabelBehavior.never,
                    ),
                  ),
                  SizedBox(height: 16),

                  // Confirm Password Field (Sign Up Only)
                  AnimatedSize(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOut,
                    alignment: Alignment.topCenter,
                    child: _isSignUpMode
                        ? Column(
                            children: [
                              TextFormField(
                                controller: _confirmPasswordController,
                                obscureText: _obscureConfirmPassword,
                                style: GoogleFonts.montserrat(color: _C.ink, fontWeight: FontWeight.bold),
                                validator: (val) {
                                  if (val == null || val.isEmpty) return 'Please confirm your password';
                                  if (val != _passwordController.text) return 'Passwords do not match';
                                  return null;
                                },
                                decoration: InputDecoration(
                                  labelText: 'Confirm Password',
                                  labelStyle: GoogleFonts.montserrat(color: _C.grey60, fontWeight: FontWeight.bold),
                                  prefixIcon: const Icon(LucideIcons.lock, size: 18, color: _C.grey60),
                                  suffixIcon: IconButton(
                                    icon: Icon(
                                      _obscureConfirmPassword ? LucideIcons.eyeOff : LucideIcons.eye,
                                      size: 18,
                                      color: _C.grey60,
                                    ),
                                    onPressed: () {
                                      setState(() {
                                        _obscureConfirmPassword = !_obscureConfirmPassword;
                                      });
                                    },
                                  ),
                                  filled: true,
                                  fillColor: _C.surface,
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(16),
                                    borderSide: const BorderSide(color: _C.border, width: 1.5),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(16),
                                    borderSide: const BorderSide(color: _C.border, width: 1.5),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(16),
                                    borderSide: const BorderSide(color: _C.ink, width: 2),
                                  ),
                                  floatingLabelBehavior: FloatingLabelBehavior.never,
                                ),
                              ),
                              SizedBox(height: 32),
                            ],
                          )
                        : SizedBox(height: 16),
                  ),

                  // Submit button
                  Container(
                    decoration: BoxDecoration(
                      boxShadow: const [
                        BoxShadow(
                          color: _C.ink,
                          offset: Offset(4, 4),
                          blurRadius: 0,
                        ),
                      ],
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: ElevatedButton(
                      onPressed: _isLoading || (_isSignUpMode && (_isChecking || _isAvailable == false)) 
                          ? null 
                          : _handleSubmit,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _C.ink,
                        foregroundColor: _C.bg,
                        disabledBackgroundColor: _C.ink.withValues(alpha: 0.5),
                        disabledForegroundColor: _C.bg.withValues(alpha: 0.5),
                        minimumSize: const Size.fromHeight(56),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: const BorderSide(color: _C.ink, width: 1.5),
                        ),
                        elevation: 0,
                      ),
                      child: _isLoading 
                          ? SizedBox(
                              width: 24, 
                              height: 24, 
                              child: CircularProgressIndicator(color: _C.bg, strokeWidth: 2),
                            )
                          : AnimatedSwitcher(
                              duration: const Duration(milliseconds: 300),
                              transitionBuilder: (Widget child, Animation<double> animation) {
                                return SlideTransition(
                                  position: Tween<Offset>(
                                    begin: const Offset(0.0, 0.5),
                                    end: Offset.zero,
                                  ).animate(animation),
                                  child: FadeTransition(
                                    opacity: animation,
                                    child: child,
                                  ),
                                );
                              },
                              child: Text(
                                _isSignUpMode ? 'CREATE PROFILE' : 'LOG IN', 
                                key: ValueKey<bool>(_isSignUpMode),
                                style: GoogleFonts.montserrat(fontWeight: FontWeight.w900, fontSize: 16, letterSpacing: 1),
                              ),
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
}
