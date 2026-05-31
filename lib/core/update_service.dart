import 'package:google_fonts/google_fonts.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:app_updater/app_updater.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'dart:isolate';

@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse response) {
  if (response.actionId == 'cancel_update') {
    final sendPort = IsolateNameServer.lookupPortByName('update_service_port');
    sendPort?.send('cancel');
  }
}

// ─── Design Tokens (matches OmniDrop theme) ──────────────────────────────────
class _C {
  static const bg      = Color(0xFFF5F0E8);
  static const surface = Color(0xFFEDE8DF);
  static const ink     = Color(0xFF0A0A0A);
  static const grey60  = Color(0xFF8A8278);
  static const border  = Color(0xFFD4CEC4);
  static const success = Color(0xFF2D7A4F);
  static const error   = Color(0xFFC0392B);
}

const _githubOwner = 'Sanjeev1412-official';
const _githubRepo  = 'OmniDrop';
// FileProvider authority must match android:authorities in AndroidManifest.xml
const _fileProviderAuthority = 'com.example.omnidrop.fileprovider';

/// Tracks the active download so it can run in the background.
class ActiveDownload {
  final String newVersion;
  final String downloadUrl;

  final ValueNotifier<double> progress = ValueNotifier(0);
  final ValueNotifier<int> received = ValueNotifier(0);
  final ValueNotifier<int> total = ValueNotifier(0);
  final ValueNotifier<String> status = ValueNotifier('Connecting...');

  bool isFailed = false;
  bool isInstalling = false;
  bool isCancelled = false;

  http.Client? client;

  ActiveDownload({required this.newVersion, required this.downloadUrl});
}

/// Auto-update service for OmniDrop.
/// Downloads and installs updates in-app from GitHub Releases.
class UpdateService {
  UpdateService._();
  static final UpdateService _instance = UpdateService._();
  factory UpdateService() => _instance;

  late final AppUpdater _appUpdater;
  final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  bool _notificationsInitialized = false;
  Future<void>? _initNotificationsFuture;

  ActiveDownload? _activeDownload;
  ActiveDownload? get activeDownload => _activeDownload;

  void _init() {
    if (_initialized) return;
    _initialized = true;

    // Set up isolate port for background notification actions
    final port = ReceivePort();
    IsolateNameServer.removePortNameMapping('update_service_port');
    IsolateNameServer.registerPortWithName(port.sendPort, 'update_service_port');
    port.listen((message) {
      if (message == 'cancel') {
        cancelActiveDownload();
      }
    });

    _appUpdater = AppUpdater.configure(
      githubOwner: _githubOwner,
      githubRepo: _githubRepo,
      githubIncludePrereleases: false,
      // [TEST DEMO] Set to 0 to test instantly. Change back to Duration(days: 1) before release!
      checkFrequency: const Duration(seconds: 0),
    );
  }

  Future<void> _initNotifications() {
    if (_notificationsInitialized || !Platform.isAndroid) return Future.value();
    
    _initNotificationsFuture ??= _doInitNotifications().whenComplete(() {
      _initNotificationsFuture = null;
    });
    return _initNotificationsFuture!;
  }

  Future<void> _doInitNotifications() async {
    const initSettingsAndroid = AndroidInitializationSettings('ic_qs_omnidrop');
    const initSettings = InitializationSettings(android: initSettingsAndroid);
    await _notifications.initialize(
      settings: initSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        if (response.actionId == 'cancel_update') {
          UpdateService().cancelActiveDownload();
        }
      },
      onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
    );

    try {
      final androidPlugin = _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      if (androidPlugin != null) {
        await androidPlugin.requestNotificationsPermission();
      }
    } catch (e) {
      // Ignore if another permission request is active or if it fails
      debugPrint('[UpdateService] Failed to request notification permission: $e');
    }

    _notificationsInitialized = true;
  }

  Future<void> checkForUpdates(BuildContext context) async {
    try {
      _init();
      final info = await _appUpdater.checkForUpdate();
      if (!info.updateAvailable) return;
      if (!context.mounted) return;

      final prefs = await SharedPreferences.getInstance();
      final skippedVer = prefs.getString('omnidrop_update_skipped');
      if (skippedVer != null && skippedVer == info.latestVersion) return;
      final doNotAsk = prefs.getBool('omnidrop_update_do_not_ask') ?? false;
      if (doNotAsk) return;

      if (!context.mounted) return;
      final assetUrl = await _getAssetDownloadUrl(info.latestVersion);

      if (!context.mounted) return;
      await showDialog(
        context: context,
        barrierDismissible: true,
        barrierColor: Colors.black45,
        builder: (_) => _OmniDropUpdateDialog(
          currentVersion: info.currentVersion,
          newVersion: info.latestVersion ?? 'New',
          releaseNotes: info.releaseNotes,
          assetUrl: assetUrl,
          onUpdate: (url) => _beginInAppUpdate(context, url, info.latestVersion ?? ''),
          onSkipVersion: () async {
            if (info.latestVersion != null) {
              await prefs.setString('omnidrop_update_skipped', info.latestVersion!);
            }
          },
          onDoNotAsk: () async {
            await prefs.setBool('omnidrop_update_do_not_ask', true);
          },
        ),
      );
    } catch (e) {
      debugPrint('[UpdateService] Update check failed: $e');
    }
  }

  Future<void> checkForUpdatesNow(BuildContext context) async {
    try {
      _init();
      final info = await _appUpdater.checkForUpdate(respectFrequency: false);
      if (!context.mounted) return;
      if (info.updateAvailable) {
        final assetUrl = await _getAssetDownloadUrl(info.latestVersion);
        if (!context.mounted) return;
        await showDialog(
          context: context,
          barrierColor: Colors.black45,
          builder: (_) => _OmniDropUpdateDialog(
            currentVersion: info.currentVersion,
            newVersion: info.latestVersion ?? 'New',
            releaseNotes: info.releaseNotes,
            assetUrl: assetUrl,
            onUpdate: (url) => _beginInAppUpdate(context, url, info.latestVersion ?? ''),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('OmniDrop is already up to date!'), behavior: SnackBarBehavior.floating),
        );
      }
    } catch (e) {
      debugPrint('[UpdateService] Manual check failed: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not check for updates. Try again later.'), behavior: SnackBarBehavior.floating),
        );
      }
    }
  }

  Future<String?> _getAssetDownloadUrl(String? version) async {
    try {
      final apiUrl = version != null
          ? 'https://api.github.com/repos/$_githubOwner/$_githubRepo/releases/tags/$version'
          : 'https://api.github.com/repos/$_githubOwner/$_githubRepo/releases/latest';

      final response = await http.get(
        Uri.parse(apiUrl),
        headers: {'Accept': 'application/vnd.github+json'},
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) return null;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final assets = (data['assets'] as List<dynamic>?) ?? [];

      final extension = Platform.isAndroid ? '.apk' : (Platform.isWindows ? '.exe' : null);
      if (extension == null) return null;

      for (final asset in assets) {
        final name = (asset['name'] as String? ?? '').toLowerCase();
        if (name.endsWith(extension)) {
          return asset['browser_download_url'] as String?;
        }
      }
    } catch (e) {
      debugPrint('[UpdateService] Failed to fetch asset URL: $e');
    }
    return null;
  }

  Future<void> _beginInAppUpdate(BuildContext context, String? assetUrl, String newVersion) async {
    if (assetUrl == null) {
      await _appUpdater.openStore();
      return;
    }

    if (_activeDownload != null && !_activeDownload!.isFailed && !_activeDownload!.isCancelled) {
      // Download already running, just show the dialog
      _showProgressDialog(context);
      return;
    }

    _activeDownload = ActiveDownload(newVersion: newVersion, downloadUrl: assetUrl);
    _startBackgroundDownload();
    _showProgressDialog(context);
  }

  void _showProgressDialog(BuildContext context) {
    showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black54,
      builder: (_) => _DownloadProgressDialog(
        activeDownload: _activeDownload!,
        onRetry: () {
          _activeDownload = ActiveDownload(newVersion: _activeDownload!.newVersion, downloadUrl: _activeDownload!.downloadUrl);
          _startBackgroundDownload();
          Navigator.pop(context);
          _showProgressDialog(context);
        },
        onCancel: () {
          cancelActiveDownload();
          Navigator.pop(context);
        },
      ),
    );
  }

  void cancelActiveDownload() {
    if (_activeDownload != null) {
      _activeDownload!.isCancelled = true;
      _activeDownload!.client?.close();
      _activeDownload = null;
      _notifications.cancel(id: 890);
    }
  }

  Future<void> _updateNotification(int maxProgress, int progress, String body) async {
    if (!Platform.isAndroid) return;
    if (_activeDownload == null || _activeDownload!.isInstalling || _activeDownload!.isFailed || _activeDownload!.isCancelled) {
      return;
    }
    await _initNotifications();

    final androidPlatformChannelSpecifics = AndroidNotificationDetails(
      'omnidrop_updates',
      'App Updates',
      channelDescription: 'Notifications for downloading app updates',
      importance: Importance.low,
      priority: Priority.low,
      showProgress: true,
      maxProgress: maxProgress,
      progress: progress,
      indeterminate: maxProgress == 0,
      ongoing: true,
      onlyAlertOnce: true,
      actions: const <AndroidNotificationAction>[
        AndroidNotificationAction(
          'cancel_update',
          'Cancel',
          cancelNotification: true,
          showsUserInterface: true,
        ),
      ],
    );
    final platformChannelSpecifics = NotificationDetails(android: androidPlatformChannelSpecifics);

    if (_activeDownload == null || _activeDownload!.isCancelled) return;

    await _notifications.show(
      id: 890,
      title: 'Downloading Update v${_activeDownload?.newVersion}',
      body: body,
      notificationDetails: platformChannelSpecifics,
    );
  }

  Future<void> _showFinishedNotification(bool success) async {
    if (!Platform.isAndroid) return;
    await _initNotifications();
    
    // Clear the ongoing progress notification
    await _notifications.cancel(id: 890);

    if (!success) {
      const androidDetails = AndroidNotificationDetails(
        'omnidrop_updates', 'App Updates',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
      );
      await _notifications.show(
        id: 889,
        title: 'Update Failed',
        body: 'Could not download the update.',
        notificationDetails: const NotificationDetails(android: androidDetails),
      );
    }
  }

  Future<void> _startBackgroundDownload() async {
    final download = _activeDownload!;
    try {
      final tmpDir = await getTemporaryDirectory();
      final ext = Platform.isAndroid ? '.apk' : '.exe';
      final savePath = '${tmpDir.path}/OmniDrop-${download.newVersion}$ext';

      download.client = http.Client();
      final request = http.Request('GET', Uri.parse(download.downloadUrl));
      final response = await download.client!.send(request);

      final totalBytes = response.contentLength ?? 0;
      int received = 0;

      download.total.value = totalBytes;
      download.status.value = 'Downloading...';

      final file = File(savePath);
      final sink = file.openWrite();

      // Update notification every 1 second to avoid spamming the OS
      Timer? notifTimer;
      if (Platform.isAndroid) {
        notifTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
          if (!download.isCancelled && !download.isFailed) {
            _updateNotification(totalBytes, received, '${(received / (1024 * 1024)).toStringAsFixed(1)} MB / ${(totalBytes / (1024 * 1024)).toStringAsFixed(1)} MB');
          }
        });
      }

      await for (final chunk in response.stream) {
        if (download.isCancelled) {
          await sink.close();
          notifTimer?.cancel();
          return;
        }
        sink.add(chunk);
        received += chunk.length;
        
        download.received.value = received;
        download.progress.value = totalBytes > 0 ? received / totalBytes : 0;
      }

      await sink.flush();
      await sink.close();
      notifTimer?.cancel();

      if (download.isCancelled) return;

      download.isInstalling = true;
      download.status.value = 'Installing...';
      download.progress.value = 1.0;
      
      await _showFinishedNotification(true);
      await _installUpdate(savePath);

    } catch (e) {
      if (download.isCancelled) return;
      debugPrint('[UpdateService] Download error: $e');
      download.isFailed = true;
      download.status.value = 'Download failed';
      await _showFinishedNotification(false);
    }
  }

  Future<void> _installUpdate(String filePath) async {
    if (Platform.isAndroid) {
      final fileName = filePath.split('/').last;
      final contentUri = 'content://$_fileProviderAuthority/cache/$fileName';
      final intent = AndroidIntent(
        action: 'action_view',
        data: contentUri,
        type: 'application/vnd.android.package-archive',
        flags: [0x00000001, 0x10000000],
      );
      await intent.launch();
    } else if (Platform.isWindows) {
      await Process.start(filePath, [], mode: ProcessStartMode.detached, runInShell: false);
      await Future.delayed(const Duration(seconds: 1));
      exit(0);
    }
  }

  void dispose() {
    if (_initialized) {
      _appUpdater.dispose();
      _initialized = false;
    }
  }
}

// ─── Update Available Dialog ──────────────────────────────────────────────────
class _OmniDropUpdateDialog extends StatelessWidget {
  final String currentVersion;
  final String newVersion;
  final String? releaseNotes;
  final String? assetUrl;
  final void Function(String? url) onUpdate;
  final VoidCallback? onSkipVersion;
  final VoidCallback? onDoNotAsk;

  const _OmniDropUpdateDialog({
    required this.currentVersion,
    required this.newVersion,
    required this.onUpdate,
    this.releaseNotes,
    this.assetUrl,
    this.onSkipVersion,
    this.onDoNotAsk,
  });

  @override
  Widget build(BuildContext context) {
    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
      child: Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 360),
          decoration: BoxDecoration(
            color: _C.bg,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: _C.ink, width: 2),
            boxShadow: const [BoxShadow(color: _C.ink, offset: Offset(4, 4), blurRadius: 0)],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                decoration: const BoxDecoration(
                  color: _C.ink,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text('Update Available',
                        style: GoogleFonts.montserrat(color: _C.bg, fontWeight: FontWeight.w900, fontSize: 16, letterSpacing: -0.3)),
                    SizedBox(height: 4),
                    Text('A new version of OmniDrop is ready',
                        style: TextStyle(color: Color(0xFFB8B0A4), fontSize: 12, fontWeight: FontWeight.w500)),
                  ],
                ),
              ),
              // Version pill
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: _C.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: _C.border, width: 1.5),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _VersionChip(label: 'CURRENT', version: 'v$currentVersion', muted: true),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Icon(Icons.arrow_forward_rounded, size: 18, color: _C.grey60),
                      ),
                      _VersionChip(label: 'LATEST', version: 'v$newVersion', muted: false),
                    ],
                  ),
                ),
              ),
              // Release notes
              if (releaseNotes != null && releaseNotes!.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("WHAT'S NEW",
                          style: GoogleFonts.montserrat(fontSize: 10, fontWeight: FontWeight.w800, color: _C.grey60, letterSpacing: 1.5)),
                      SizedBox(height: 8),
                      Container(
                        constraints: const BoxConstraints(maxHeight: 110),
                        child: SingleChildScrollView(
                          child: Text(releaseNotes!,
                              style: TextStyle(fontSize: 13, color: _C.ink, height: 1.5, fontWeight: FontWeight.w500)),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
                child: Container(height: 1, color: _C.border),
              ),
              // Actions
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    GestureDetector(
                      onTap: () {
                        Navigator.of(context).pop();
                        onUpdate(assetUrl);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        decoration: BoxDecoration(
                          color: _C.ink,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: _C.ink, width: 2),
                        ),
                        alignment: Alignment.center,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.download_rounded, color: _C.bg, size: 18),
                            SizedBox(width: 8),
                            Text(
                              assetUrl != null ? 'Download & Install' : 'View on GitHub',
                              style: GoogleFonts.montserrat(color: _C.bg, fontWeight: FontWeight.w900, fontSize: 14, letterSpacing: 0.3),
                            ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _TextAction(label: 'Later', onTap: () => Navigator.of(context).pop()),
                        Container(width: 1, height: 16, color: _C.border),
                        _TextAction(
                          label: 'Skip version',
                          onTap: () {
                            Navigator.of(context).pop();
                            onSkipVersion?.call();
                          },
                        ),
                      ],
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

// ─── Download Progress Dialog ─────────────────────────────────────────────────
class _DownloadProgressDialog extends StatelessWidget {
  final ActiveDownload activeDownload;
  final VoidCallback onRetry;
  final VoidCallback onCancel;

  const _DownloadProgressDialog({
    required this.activeDownload,
    required this.onRetry,
    required this.onCancel,
  });

  String _fmt(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
      child: Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 340),
          decoration: BoxDecoration(
            color: _C.bg,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: _C.ink, width: 2),
            boxShadow: const [BoxShadow(color: _C.ink, offset: Offset(4, 4), blurRadius: 0)],
          ),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ValueListenableBuilder<double>(
              valueListenable: activeDownload.progress,
              builder: (context, progress, child) {
                // Determine states
                final bool isInstalling = activeDownload.isInstalling;
                final bool isFailed = activeDownload.isFailed;
                final int received = activeDownload.received.value;
                final int total = activeDownload.total.value;

                // Auto-close dialog if installing (since intent takes over)
                if (isInstalling && Platform.isAndroid) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (context.mounted && Navigator.canPop(context)) {
                      Navigator.pop(context);
                    }
                  });
                }

                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Icon + title row
                    Row(
                      children: [
                        Container(
                          width: 44, height: 44,
                          decoration: BoxDecoration(color: _C.ink, borderRadius: BorderRadius.circular(12)),
                          child: Icon(
                            isFailed ? Icons.error_outline_rounded
                                : isInstalling ? Icons.check_circle_outline_rounded
                                : Icons.download_rounded,
                            color: isFailed ? _C.error : _C.bg,
                            size: 24,
                          ),
                        ),
                        SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                isInstalling ? 'Installing...' : isFailed ? 'Download Failed' : 'Downloading Update',
                                style: GoogleFonts.montserrat(fontWeight: FontWeight.w900, fontSize: 15, color: _C.ink, letterSpacing: -0.3),
                              ),
                              Text(
                                'v${activeDownload.newVersion}',
                                style: GoogleFonts.montserrat(fontSize: 12, color: _C.grey60, fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),

                    SizedBox(height: 24),

                    // Progress bar
                    if (!isFailed) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: LinearProgressIndicator(
                          value: isInstalling ? 1.0 : (progress > 0 ? progress : null),
                          minHeight: 8,
                          backgroundColor: _C.surface,
                          valueColor: AlwaysStoppedAnimation<Color>(isInstalling ? _C.success : _C.ink),
                        ),
                      ),
                      SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            isInstalling
                                ? 'Installing...'
                                : total > 0
                                    ? '${_fmt(received)} / ${_fmt(total)}'
                                    : _fmt(received),
                            style: GoogleFonts.montserrat(fontSize: 12, color: _C.grey60, fontWeight: FontWeight.w600),
                          ),
                          if (total > 0 && !isInstalling)
                            Text(
                              '${(progress * 100).toInt()}%',
                              style: GoogleFonts.montserrat(fontSize: 12, fontWeight: FontWeight.w800, color: _C.ink),
                            ),
                        ],
                      ),
                    ],

                    // Error message
                    if (isFailed) ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFBE9E7),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: _C.error.withValues(alpha: 0.4)),
                        ),
                        child: Text(
                          'The download could not be completed. Please check your internet connection and try again.',
                          style: TextStyle(fontSize: 12, color: _C.error, height: 1.4),
                        ),
                      ),
                    ],

                    SizedBox(height: 20),

                    // Actions
                    if (!isInstalling)
                      Row(
                        children: [
                          Expanded(
                            child: GestureDetector(
                              onTap: isFailed ? onRetry : onCancel,
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                decoration: BoxDecoration(
                                  color: isFailed ? _C.ink : _C.surface,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: isFailed ? _C.ink : _C.border, width: 1.5),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  isFailed ? 'Retry Download' : 'Cancel',
                                  style: GoogleFonts.montserrat(
                                    color: isFailed ? _C.bg : _C.ink,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          if (!isFailed) ...[
                            SizedBox(width: 12),
                            Expanded(
                              child: GestureDetector(
                                onTap: () => Navigator.of(context).pop(), // Just hides the dialog
                                child: Container(
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                  decoration: BoxDecoration(
                                    color: _C.ink,
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: _C.ink, width: 1.5),
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    'Run in Background',
                                    style: GoogleFonts.montserrat(
                                      color: _C.bg,
                                      fontWeight: FontWeight.w800,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Shared sub-widgets ───────────────────────────────────────────────────────
class _VersionChip extends StatelessWidget {
  final String label;
  final String version;
  final bool muted;
  const _VersionChip({required this.label, required this.version, required this.muted});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(label, style: GoogleFonts.montserrat(fontSize: 9, fontWeight: FontWeight.w800,
            color: _C.grey60, letterSpacing: 1.2)),
        SizedBox(height: 2),
        Text(version, style: GoogleFonts.montserrat(fontSize: 15, fontWeight: FontWeight.w900,
            color: muted ? _C.grey60 : _C.ink, letterSpacing: -0.5)),
      ],
    );
  }
}

class _TextAction extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _TextAction({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        child: Text(label,
            style: GoogleFonts.montserrat(fontSize: 13, fontWeight: FontWeight.w600, color: _C.grey60)),
      ),
    );
  }
}
