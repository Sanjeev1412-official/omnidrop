import 'package:flutter/material.dart';
import 'package:app_updater/app_updater.dart';

/// Auto-update service for OmniDrop.
/// Checks GitHub Releases for new versions once per day.
/// 
/// HOW TO USE:
/// 1. Replace 'YOUR_GITHUB_USERNAME' with your GitHub username/organization.
/// 2. Replace 'YOUR_GITHUB_REPO' with the repository name (e.g. 'omnidrop').
/// 3. On every release, create a GitHub Release tagged as 'v1.2.3' matching pubspec.yaml version.
/// 4. Attach the APK (for Android) and/or installer (for Windows) as release assets.
class UpdateService {
  UpdateService._();
  static final UpdateService _instance = UpdateService._();
  factory UpdateService() => _instance;

  late final AppUpdater _appUpdater;
  bool _initialized = false;

  void _init() {
    if (_initialized) return;
    _initialized = true;
    _appUpdater = AppUpdater.configure(
      // ─── GitHub Releases (replace with your actual repo details) ───────────
      githubOwner: 'Sanjeev1412-official', 
      githubRepo: 'OmniDrop',      
      githubIncludePrereleases: false,
      // ─── Check frequency ───────────────────────────────────────────────────
      checkFrequency: const Duration(days: 1), // At most once per day
    );
  }

  /// Checks for updates silently. Shows a dialog only if a new version is available.
  /// Safe to call every startup — respects the 1-day cooldown.
  Future<void> checkForUpdates(BuildContext context) async {
    try {
      _init();
      await _appUpdater.checkAndShowUpdateDialog(
        context,
        showSkipVersion: true,       // Let users skip a specific version
        showDoNotAskAgain: true,     // Let users mute all future prompts
        showReleaseNotes: true,      // Show changelog from the GitHub release body
        title: 'Update Available ✨',
        message:
            'A new version of OmniDrop is ready! Update now to get the latest features and fixes.',
      );
    } catch (e) {
      // Silently swallow update check errors — never block the user experience
      debugPrint('[UpdateService] Update check failed: $e');
    }
  }

  /// Force-check ignoring the 1-day cooldown (e.g. from Settings screen).
  Future<void> checkForUpdatesNow(BuildContext context) async {
    try {
      _init();
      final info = await _appUpdater.checkForUpdate(respectFrequency: false);
      if (!context.mounted) return;
      if (info.updateAvailable) {
        await _appUpdater.showUpdateDialog(
          context,
          showSkipVersion: true,
          showDoNotAskAgain: true,
          showReleaseNotes: true,
          title: 'Update Available ✨',
          message:
              'A new version of OmniDrop is ready! Update now to get the latest features and fixes.',
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('OmniDrop is up to date!'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      debugPrint('[UpdateService] Manual update check failed: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not check for updates. Try again later.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  void dispose() {
    if (_initialized) {
      _appUpdater.dispose();
      _initialized = false;
    }
  }
}
