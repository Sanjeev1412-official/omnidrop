import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:omnidrop/core/p2p_manager.dart';
import 'package:omnidrop/supabase_config.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> initializeBackgroundService() async {
  // flutter_background_service and flutter_local_notifications are Android/iOS only.
  // Skip entirely on Windows/Desktop to prevent crashes.
  if (!Platform.isAndroid && !Platform.isIOS) return;

  final service = FlutterBackgroundService();

  // Initialize notifications for the foreground service
  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'omnidrop_foreground', // id
    'OmniDrop Background Listener', // title
    description: 'This channel is used for OmniDrop background file receiving.',
    importance: Importance.low, // low importance so it doesn't make a sound
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      // autoStart: false — the background service is user-controlled via the Quick Tile.
      // Setting this to true would immediately launch a foreground service notification
      // on every app start (including first-time onboarding), causing ANR on some
      // Android versions and an unwanted persistent notification.
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: 'omnidrop_foreground',
      initialNotificationTitle: 'OmniDrop Quick Share',
      initialNotificationContent: 'Listening for incoming files...',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
  );
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  return true;
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  // DartPluginRegistrant registers all Flutter plugins in this background isolate
  // so method channels (SharedPreferences, path_provider, etc.) work correctly.
  // DO NOT call WidgetsFlutterBinding.ensureInitialized() here — the
  // flutter_background_service plugin sets up its own Flutter engine and calling
  // this can interfere with the plugin's internal message pump setup.
  DartPluginRegistrant.ensureInitialized();
  
  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((event) {
      service.setAsForegroundService();
    });

    service.on('setAsBackground').listen((event) {
      service.setAsBackgroundService();
    });
  }

  service.on('stopService').listen((event) {
    service.stopSelf();
  });

  service.on('update_profile').listen((event) async {
    if (event != null) {
      final displayName = event['displayName'] as String?;
      final avatar = event['avatar'] as String?;
      
      if (displayName != null) {
        P2PManager().updateDisplayName(displayName);
      }
      
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.reload();
        if (displayName != null) {
          await prefs.setString('display_name', displayName);
        }
        if (avatar != null) {
          await prefs.setString('profile_image', avatar);
        } else {
          await prefs.remove('profile_image');
        }
      } catch (e) {
        debugPrint('[BackgroundService] Error saving profile in background service: $e');
      }
    }
  });

  // Initialize Supabase inside this background isolate.
  // The background service runs in its own Dart isolate — Supabase initialized
  // in main() is NOT available here and must be re-initialized independently.
  if (SupabaseConfig.isSupabaseConfigured) {
    try {
      await Supabase.initialize(
        url: SupabaseConfig.supabaseUrl,
        anonKey: SupabaseConfig.supabaseAnonKey,
      );
      debugPrint('[BackgroundService] Supabase initialized in background isolate');
    } catch (e) {
      // Supabase may already be initialized if the service restarted in the same process.
      // This is safe to ignore.
      debugPrint('[BackgroundService] Supabase init skipped (already initialized or failed): $e');
    }
  }

  // Initialize P2PManager to start listening on sockets
  // Make sure we have a username set, otherwise it won't initialize properly.
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload(); // Reload in case it was changed in the main app
  
  final isProfileCreated = prefs.getString('username') != null;
  if (isProfileCreated) {
    await P2PManager().init(isBackgroundIsolate: true);
    
    // Listen for P2P events to update the notification dynamically
    P2PManager().eventStream.listen((event) {
      service.invoke('p2p_event', {
        'peerUsername': event.peerUsername,
        'message': event.message?.toJson(),
        'isProgressUpdate': event.isProgressUpdate,
        'isConnectionStatusUpdate': event.isConnectionStatusUpdate,
        'isProfileUpdate': event.isProfileUpdate,
        'toastMessage': event.toastMessage,
      });

      if (service is AndroidServiceInstance) {
        if (event.isConnectionStatusUpdate) {
          service.setForegroundNotificationInfo(
            title: 'OmniDrop Quick Share',
            content: 'Connected to @${event.peerUsername}',
          );
        } else if (event.isProgressUpdate && event.message?.fileName != null) {
          final progress = ((event.message?.transferProgress ?? 0) * 100).toInt();
          service.setForegroundNotificationInfo(
            title: 'Receiving ${event.message!.fileName}',
            content: 'Progress: $progress%',
          );
          
          if (event.message?.isTransferComplete == true) {
            Future.delayed(const Duration(seconds: 1), () {
              service.setForegroundNotificationInfo(
                title: 'OmniDrop Quick Share',
                content: 'File received from @${event.peerUsername}',
              );
            });
          }
        } else if (event.message?.text != null) {
          service.setForegroundNotificationInfo(
            title: 'OmniDrop - @${event.peerUsername}',
            content: event.message!.text,
          );
        }
      }
    });
  }

  // Periodic keep-alive — keeps the foreground service alive
  Timer.periodic(const Duration(seconds: 10), (timer) async {
    if (service is AndroidServiceInstance) {
      if (await service.isForegroundService()) {
        // Keeps the service alive and can be used for fallback checks
      }
    }
  });
}
