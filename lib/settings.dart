import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:omnidrop/core/sync_service.dart';
import 'package:omnidrop/supabase_config.dart';

// Neo-Brutalist Colors
class _C {
  static const bg = Color(0xFFF5F0E8);
  static const surface = Color.fromARGB(255, 237, 232, 223);
  static const ink = Color(0xFF0A0A0A);
  static const border = Color(0xFFD4CEC4);
  static const grey60 = Color(0xFF8A8278);
  static const onlineDot = Color(0xFF2ECC71);
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _backupEnabled = false;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final enabled = await SyncService().isBackupEnabled();
    if (mounted) {
      setState(() {
        _backupEnabled = enabled;
        _isLoading = false;
      });
    }
  }

  Future<void> _toggleBackup(bool value) async {
    setState(() => _isLoading = true);
    await SyncService().setBackupEnabled(value);
    if (mounted) {
      setState(() {
        _backupEnabled = value;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _C.bg,
      
      body: _isLoading 
        ? const Center(child: CircularProgressIndicator(color: _C.ink))
        : SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
              child: Row(
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
                      child: const Icon(LucideIcons.arrowLeft, size: 20, color: _C.ink),
                    ),
                  ),
                  const SizedBox(width: 24),
                  const Text(
                    'Preferences.',
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w900,
                      color: _C.ink,
                      letterSpacing: -1.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
              Expanded(
                child: ListView(
                    padding: const EdgeInsets.all(24),
                    children: [
                      
                      
                      Container(
                        decoration: BoxDecoration(
                          color: _C.surface,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: _C.border, width: 1.5),
                          boxShadow: const [
                            BoxShadow(
                              color: _C.ink,
                              offset: Offset(4, 4),
                              blurRadius: 0,
                            ),
                          ],
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: _C.bg,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: _C.border),
                              ),
                              child: const Icon(LucideIcons.cloudLightning, color: _C.ink, size: 24),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text('Backup & Sync', style: TextStyle(color: _C.ink, fontWeight: FontWeight.bold, fontSize: 16)),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Requires an active internet connection.',
                                    style: TextStyle(color: _C.grey60, fontSize: 11, height: 1.4),
                                  ),
                                  if (!SupabaseConfig.isSupabaseConfigured) ...[
                                    const SizedBox(height: 8),
                                    const Text(
                                      'Cloud backup is disabled in local sandbox mode.',
                                      style: TextStyle(color: Colors.amber, fontSize: 12, fontWeight: FontWeight.w600),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            const SizedBox(width: 16),
                            Switch(
                              value: _backupEnabled,
                              onChanged: SupabaseConfig.isSupabaseConfigured ? _toggleBackup : null,
                              activeColor: _C.onlineDot,
                              activeTrackColor: _C.ink,
                              inactiveThumbColor: _C.grey60,
                              inactiveTrackColor: _C.border,
                            ),
                          ],
                        ),
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
