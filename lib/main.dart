import 'package:flutter/material.dart';
import 'package:omnidrop/homepage.dart';
import 'package:omnidrop/splash_screen.dart';
import 'package:omnidrop/onboarding.dart';
import 'package:omnidrop/supabase_config.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:omnidrop/core/p2p_manager.dart';
import 'package:omnidrop/core/background_service.dart';
import 'package:lottie/lottie.dart';

import 'dart:io';
import 'package:window_manager/window_manager.dart';
import 'package:launch_at_startup/launch_at_startup.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    WindowOptions windowOptions = const WindowOptions(
      size: Size(1100, 750),
      minimumSize: Size(800, 600),
      center: true,
      skipTaskbar: false,
      title: "OmniDrop",
    );
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
    
    launchAtStartup.setup(
      appName: 'OmniDrop',
      appPath: Platform.resolvedExecutable,
    );
    await launchAtStartup.enable();
  }


  // Run initialization without blocking the main UI thread.
  initializeBackgroundService().catchError((e) {
    debugPrint('Background service initialization failed: $e');
  });
  
  // Preload heavy Lottie JSON videos in the background so they play instantly later
  AssetLottie('assets/quicktile.json').load().catchError((e) {
    debugPrint('Failed to preload Lottie: $e');
  });
  
  if (SupabaseConfig.isSupabaseConfigured) {
    try {
      await Supabase.initialize(
        url: SupabaseConfig.supabaseUrl,
        anonKey: SupabaseConfig.supabaseAnonKey,
      );
    } catch (e) {
      debugPrint('Supabase initialization error: $e');
    }
  }

  

  final prefs = await SharedPreferences.getInstance();
  
  // Evaluate initialization flag to manage app entry point routing
  final bool isProfileCreated = prefs.getString('username') != null;

  if (isProfileCreated) {
    P2PManager().init();
  }

  runApp(OmniDropApp(initialScreen: isProfileCreated 
      ? const HomeScreen() 
      : const ProfileSetupScreen()));
}

class OmniDropApp extends StatelessWidget {
  final Widget initialScreen;
  const OmniDropApp({super.key, required this.initialScreen});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'OmniDrop',
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F172A), // Slate 950
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
          surface: const Color(0xFF1E293B), // Slate 800
        ),
      ),
      home: SplashScreen(nextScreen: initialScreen),
    );
  }
}

