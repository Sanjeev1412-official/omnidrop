import 'package:google_fonts/google_fonts.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'core/update_service.dart';

// Neo-brutalist theme constants
class _C {
  static const bg = Color(0xFFF5F0E8);
  static const surface = Color(0xFFEDE8DF);
  static const ink = Color(0xFF0A0A0A);
  static const grey60 = Color(0xFF8A8278);
  static const border = Color(0xFFD4CEC4);
  static const success = Color(0xFF2D7A4F);
  static const error = Color(0xFFC0392B);
}

class UpdateCheckPage extends StatefulWidget {
  const UpdateCheckPage({super.key});

  @override
  State<UpdateCheckPage> createState() => _UpdateCheckPageState();
}

class _UpdateCheckPageState extends State<UpdateCheckPage> {
  String _currentVersion = 'Loading...';
  bool _isChecking = false;

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    setState(() {
      _currentVersion = info.version;
    });
  }

  Future<void> _checkNow() async {
    setState(() => _isChecking = true);
    await UpdateService().checkForUpdatesNow(context);
    if (mounted) setState(() => _isChecking = false);
  }

  String _fmt(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final activeDownload = UpdateService().activeDownload;

    return Scaffold(
      backgroundColor: _C.bg,

      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Container(
                      padding: const EdgeInsets.all(11),
                      decoration: BoxDecoration(
                        color: _C.surface,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: _C.border),
                      ),
                      child: const Icon(
                        LucideIcons.arrowLeft,
                        size: 20,
                        color: _C.ink,
                      ),
                    ),
                  ),
                  const SizedBox(width: 24),
                  Text(
                    'Update.',
                    style: GoogleFonts.montserrat(
                      fontSize: 32,
                      fontWeight: FontWeight.w900,
                      color: _C.ink,
                      letterSpacing: -1.5,
                    ),
                  ),
                ],
              ),

              const Spacer(),

              // App Icon / Logo Box
              Center(
                child: Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    color: _C.surface,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: _C.ink, width: 3),
                    boxShadow: const [
                      BoxShadow(color: _C.ink, offset: Offset(4, 4)),
                    ],
                  ),
                  child: const Icon(
                    LucideIcons.refreshCw,
                    size: 40,
                    color: _C.ink,
                  ),
                ),
              ),
              const SizedBox(height: 32),

              // Version Info
              Text(
                'OmniDrop',
                textAlign: TextAlign.center,
                style: GoogleFonts.montserrat(
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  color: _C.ink,
                  letterSpacing: -1,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Version $_currentVersion',
                textAlign: TextAlign.center,
                style: GoogleFonts.montserrat(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: _C.grey60,
                ),
              ),

              const SizedBox(height: 48),

              // Download Progress OR Check Button
              if (activeDownload != null)
                _buildDownloadProgress(activeDownload)
              else
                GestureDetector(
                  onTap: _isChecking ? null : _checkNow,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    decoration: BoxDecoration(
                      color: _isChecking ? _C.surface : _C.ink,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: _C.ink, width: 2),
                      boxShadow: _isChecking
                          ? []
                          : const [
                              BoxShadow(color: _C.ink, offset: Offset(4, 4)),
                            ],
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (_isChecking)
                          const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              color: _C.ink,
                              strokeWidth: 2.5,
                            ),
                          )
                        else
                          const Icon(
                            LucideIcons.search,
                            color: _C.bg,
                            size: 20,
                          ),
                        const SizedBox(width: 12),
                        Text(
                          _isChecking ? 'Checking...' : 'Check for Updates',
                          style: GoogleFonts.montserrat(
                            color: _isChecking ? _C.ink : _C.bg,
                            fontWeight: FontWeight.w900,
                            fontSize: 16,
                            letterSpacing: -0.3,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              const Spacer(flex: 2),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDownloadProgress(ActiveDownload download) {
    return ValueListenableBuilder<double>(
      valueListenable: download.progress,
      builder: (context, progress, child) {
        final isInstalling = download.isInstalling;
        final isFailed = download.isFailed;
        final received = download.received.value;
        final total = download.total.value;

        return Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: _C.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: _C.ink, width: 2),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    isInstalling
                        ? 'Installing Update...'
                        : isFailed
                        ? 'Download Failed'
                        : 'Downloading v${download.newVersion}',
                    style: GoogleFonts.montserrat(
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                      color: _C.ink,
                    ),
                  ),
                  if (!isFailed && !isInstalling && total > 0)
                    Text(
                      '${(progress * 100).toInt()}%',
                      style: GoogleFonts.montserrat(
                        fontWeight: FontWeight.w900,
                        fontSize: 14,
                        color: _C.ink,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              if (!isFailed) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: isInstalling
                        ? 1.0
                        : (progress > 0 ? progress : null),
                    minHeight: 10,
                    backgroundColor: _C.bg,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      isInstalling ? _C.success : _C.ink,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  isInstalling
                      ? 'Please wait...'
                      : total > 0
                      ? '${_fmt(received)} / ${_fmt(total)}'
                      : _fmt(received),
                  style: GoogleFonts.montserrat(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: _C.grey60,
                  ),
                ),
              ],
              if (isFailed)
                Text(
                  'Connection lost. Try again later.',
                  style: GoogleFonts.montserrat(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: _C.error,
                  ),
                ),
              const SizedBox(height: 20),
              GestureDetector(
                onTap: () {
                  if (isFailed) {
                    UpdateService().cancelActiveDownload();
                    setState(() {}); // refresh to show check button
                  } else {
                    UpdateService().cancelActiveDownload();
                    setState(() {});
                  }
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: _C.bg,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: _C.ink, width: 1.5),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    isFailed ? 'Clear' : 'Cancel Download',
                    style: GoogleFonts.montserrat(
                      color: _C.ink,
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
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
